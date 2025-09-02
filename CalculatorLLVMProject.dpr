program CalculatorLLVMProject;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  Generics.Collections,
  Dlluminator in 'LLVMSupport\Dlluminator.pas',
  libLLVM.API in 'LLVMSupport\libLLVM.API.pas',
  libLLVM.LLD in 'LLVMSupport\libLLVM.LLD.pas',
  libLLVM in 'LLVMSupport\libLLVM.pas',
  libLLVM.Utils in 'LLVMSupport\libLLVM.Utils.pas';

type
  // Token types for expression parsing
  TTokenType = (ttNumber, ttOperator, ttLeftParen, ttRightParen, ttEnd);

  TToken = record
    TokenType: TTokenType;
    Value: string;
    NumValue: Double;
  end;

  // Simple expression parser and evaluator using LLVM
  TLLVMCalculator = class
  private
    FContext: LLVMContextRef;
    FModule: LLVMModuleRef;
    FBuilder: LLVMBuilderRef;
    FExecutionEngine: LLVMExecutionEngineRef;
    FTokens: TArray<TToken>;
    FTokenIndex: Integer;

    procedure InitializeLLVM;
    procedure CleanupLLVM;
    function Tokenize(const Expression: string): TArray<TToken>;
    function GetCurrentToken: TToken;
    function PeekToken: TToken;
    procedure ConsumeToken;
    function CreateLLVMFunctionTemp(TempModule: LLVMModuleRef; TempBuilder: LLVMBuilderRef; const FunctionName: string): LLVMValueRef;
    function ParsePrimaryLLVM(Builder: LLVMBuilderRef): LLVMValueRef;
    function ParseTermLLVM(Builder: LLVMBuilderRef): LLVMValueRef;
    function ParseExprLLVM(Builder: LLVMBuilderRef): LLVMValueRef;
  public
    constructor Create;
    destructor Destroy; override;
    function EvaluateExpression(const Expression: string): Double;
  end;

constructor TLLVMCalculator.Create;
begin
  inherited Create;
  InitializeLLVM;
end;

destructor TLLVMCalculator.Destroy;
begin
  CleanupLLVM;
  inherited Destroy;
end;

procedure TLLVMCalculator.InitializeLLVM;
var
  ErrorMsg: PUTF8Char;
begin
  // Initialize LLVM
  LLVMInitializeX86TargetInfo;
  LLVMInitializeX86Target;
  LLVMInitializeX86TargetMC;
  LLVMInitializeX86AsmPrinter;

  // Create context, module and builder
  FContext := LLVMContextCreate;
  FModule := LLVMModuleCreateWithNameInContext('calculator', FContext);
  FBuilder := LLVMCreateBuilderInContext(FContext);

  // Create execution engine
  if LLVMCreateExecutionEngineForModule(@FExecutionEngine, FModule, @ErrorMsg) <> 0 then
  begin
    WriteLn('Error creating execution engine: ', string(ErrorMsg));
    LLVMDisposeMessage(ErrorMsg);
    raise Exception.Create('Failed to create LLVM execution engine');
  end;
end;

procedure TLLVMCalculator.CleanupLLVM;
begin
  if Assigned(FExecutionEngine) then
    LLVMDisposeExecutionEngine(FExecutionEngine);
  if Assigned(FBuilder) then
    LLVMDisposeBuilder(FBuilder);
  // Note: Module is disposed by ExecutionEngine
  if Assigned(FContext) then
    LLVMContextDispose(FContext);
end;

function TLLVMCalculator.Tokenize(const Expression: string): TArray<TToken>;
var
  I: Integer;
  Tokens: TList<TToken>;
  Token: TToken;
  NumStr: string;

  procedure AddToken(TokenType: TTokenType; const Value: string = ''; NumValue: Double = 0);
  begin
    Token.TokenType := TokenType;
    Token.Value := Value;
    Token.NumValue := NumValue;
    Tokens.Add(Token);
  end;

begin
  Tokens := TList<TToken>.Create;
  try
    I := 1;
    while I <= Length(Expression) do
    begin
      case Expression[I] of
        ' ', #9: Inc(I); // Skip whitespace
        '+', '-', '*', '/':
        begin
          AddToken(ttOperator, Expression[I]);
          Inc(I);
        end;
        '(':
        begin
          AddToken(ttLeftParen, '(');
          Inc(I);
        end;
        ')':
        begin
          AddToken(ttRightParen, ')');
          Inc(I);
        end;
        '0'..'9', '.':
        begin
          NumStr := '';
          while (I <= Length(Expression)) and
                (CharInSet(Expression[I], ['0'..'9', '.'])) do
          begin
            NumStr := NumStr + Expression[I];
            Inc(I);
          end;
          AddToken(ttNumber, NumStr, StrToFloat(NumStr));
        end;
        else
          raise Exception.CreateFmt('Invalid character: %s', [Expression[I]]);
      end;
    end;
    AddToken(ttEnd);
    Result := Tokens.ToArray;
  finally
    Tokens.Free;
  end;
end;

function TLLVMCalculator.GetCurrentToken: TToken;
begin
  if FTokenIndex < Length(FTokens) then
    Result := FTokens[FTokenIndex]
  else
  begin
    Result.TokenType := ttEnd;
    Result.Value := '';
    Result.NumValue := 0;
  end;
end;

function TLLVMCalculator.PeekToken: TToken;
begin
  if FTokenIndex + 1 < Length(FTokens) then
    Result := FTokens[FTokenIndex + 1]
  else
  begin
    Result.TokenType := ttEnd;
    Result.Value := '';
    Result.NumValue := 0;
  end;
end;

procedure TLLVMCalculator.ConsumeToken;
begin
  if FTokenIndex < Length(FTokens) then
    Inc(FTokenIndex);
end;


function TLLVMCalculator.CreateLLVMFunctionTemp(TempModule: LLVMModuleRef; TempBuilder: LLVMBuilderRef; const FunctionName: string): LLVMValueRef;
var
  FunctionType: LLVMTypeRef;
  Function_: LLVMValueRef;
  BasicBlock: LLVMBasicBlockRef;
  DoubleType: LLVMTypeRef;
  ResultValue: LLVMValueRef;
begin
  DoubleType := LLVMDoubleTypeInContext(FContext);

  // Create function type: () -> double
  FunctionType := LLVMFunctionType(DoubleType, nil, 0, 0);
  Function_ := LLVMAddFunction(TempModule, PUTF8Char(UTF8String(FunctionName)), FunctionType);

  // Create basic block
  BasicBlock := LLVMAppendBasicBlockInContext(FContext, Function_, 'entry');
  LLVMPositionBuilderAtEnd(TempBuilder, BasicBlock);

  // Reset token index and parse expression directly to LLVM
  FTokenIndex := 0;
  ResultValue := ParseExprLLVM(TempBuilder);

  if GetCurrentToken.TokenType <> ttEnd then
    raise Exception.Create('Unexpected token at end of expression');

  // Build return instruction
  LLVMBuildRet(TempBuilder, ResultValue);

  Result := Function_;
end;


function TLLVMCalculator.ParsePrimaryLLVM(Builder: LLVMBuilderRef): LLVMValueRef;
var
  Token: TToken;
  DoubleType: LLVMTypeRef;
  Result1: LLVMValueRef;
begin
  Token := GetCurrentToken;
  DoubleType := LLVMDoubleTypeInContext(FContext);

  case Token.TokenType of
    ttNumber:
    begin
      Result := LLVMConstReal(DoubleType, Token.NumValue);
      ConsumeToken;
    end;

    ttLeftParen:
    begin
      ConsumeToken; // consume '('
      Result1 := ParseExprLLVM(Builder);
      if GetCurrentToken.TokenType <> ttRightParen then
        raise Exception.Create('Expected )');
      ConsumeToken; // consume ')'
      Result := Result1;
    end;

    else
      raise Exception.Create('Expected number or (');
  end;
end;

function TLLVMCalculator.ParseTermLLVM(Builder: LLVMBuilderRef): LLVMValueRef;
var
  Left, Right: LLVMValueRef;
  Token: TToken;
begin
  Left := ParsePrimaryLLVM(Builder);

  while True do
  begin
    Token := GetCurrentToken;
    if (Token.TokenType = ttOperator) and ((Token.Value = '*') or (Token.Value = '/')) then
    begin
      ConsumeToken;
      Right := ParsePrimaryLLVM(Builder);

      if Token.Value = '*' then
        Left := LLVMBuildFMul(Builder, Left, Right, 'mul_tmp')
      else
        Left := LLVMBuildFDiv(Builder, Left, Right, 'div_tmp');
    end
    else
      Break;
  end;

  Result := Left;
end;

function TLLVMCalculator.ParseExprLLVM(Builder: LLVMBuilderRef): LLVMValueRef;
var
  Left, Right: LLVMValueRef;
  Token: TToken;
begin
  Left := ParseTermLLVM(Builder);

  while True do
  begin
    Token := GetCurrentToken;
    if (Token.TokenType = ttOperator) and ((Token.Value = '+') or (Token.Value = '-')) then
    begin
      ConsumeToken;
      Right := ParseTermLLVM(Builder);

      if Token.Value = '+' then
        Left := LLVMBuildFAdd(Builder, Left, Right, 'add_tmp')
      else
        Left := LLVMBuildFSub(Builder, Left, Right, 'sub_tmp');
    end
    else
      Break;
  end;

  Result := Left;
end;



function TLLVMCalculator.EvaluateExpression(const Expression: string): Double;
var
  TempModule: LLVMModuleRef;
  TempBuilder: LLVMBuilderRef;
  TempEngine: LLVMExecutionEngineRef;
  Function_: LLVMValueRef;
  FunctionPtr: Pointer;
  CalcFunc: function: Double; cdecl;
  ErrorMsg: PUTF8Char;
  FunctionName: string;
begin
  try
    // Create unique function name for each evaluation
    FunctionName := Format('calc_func_%d', [TThread.GetTickCount]);

    // Create a temporary module for this evaluation
    TempModule := LLVMModuleCreateWithNameInContext('temp_calc', FContext);
    TempBuilder := LLVMCreateBuilderInContext(FContext);

    try
      // Create execution engine for this module
      if LLVMCreateExecutionEngineForModule(@TempEngine, TempModule, @ErrorMsg) <> 0 then
      begin
        WriteLn('Error creating temporary execution engine: ', string(ErrorMsg));
        LLVMDisposeMessage(ErrorMsg);
        raise Exception.Create('Failed to create temporary LLVM execution engine');
      end;

      try
        // Tokenize the expression
        FTokens := Tokenize(Expression);

        // Create LLVM function directly using temporary module and builder
        Function_ := CreateLLVMFunctionTemp(TempModule, TempBuilder, FunctionName);

        // Get function pointer and execute
        FunctionPtr := LLVMGetPointerToGlobal(TempEngine, Function_);
        @CalcFunc := FunctionPtr;
        Result := CalcFunc();

      finally
        LLVMDisposeExecutionEngine(TempEngine);
      end;

    finally
      LLVMDisposeBuilder(TempBuilder);
      // Note: TempModule is disposed by the execution engine
    end;

  except
    on E: Exception do
    begin
      WriteLn('Error: ', E.Message);
      Result := 0;
    end;
  end;
end;

// Main program
var
  Calculator: TLLVMCalculator;
  Expression: string;
  Result: Double;

begin
  try
    WriteLn('LLVM Expression Calculator');
    WriteLn('Enter mathematical expressions (e.g., "2+3*5", "10/2-1")');
    WriteLn('Type "quit" to exit');
    WriteLn;

    Calculator := TLLVMCalculator.Create;
    try
      repeat
        Write('> ');
        ReadLn(Expression);

        Expression := Trim(Expression);
        if LowerCase(Expression) = 'quit' then
          Break;

        if Expression <> '' then
        begin
          try
            Result := Calculator.EvaluateExpression(Expression);
            WriteLn('Result: ', Result:0:6);
          except
            on E: Exception do
              WriteLn('Error: ', E.Message);
          end;
          WriteLn;
        end;

      until False;

    finally
      Calculator.Free;
    end;

  except
    on E: Exception do
      WriteLn('Fatal error: ', E.ClassName, ': ', E.Message);
  end;

  WriteLn('Press Enter to exit...');
  ReadLn;
end.
