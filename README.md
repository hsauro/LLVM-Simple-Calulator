This project implements a simple calculator using Object Pascal and llvm.

The project was created by Claude based on the following prompt:

"Can you create a simple calculator that takes as input numerical expressions such as "2+3/5" and outputs the result. The code should be written using Delphi object pascal and must use LLVM to create the evaluator. You can use the Delphi bindings to LLVM that I have attached"

I created this project to help me understand how to use LLVM from within Object Pascal.

The code uses the libLLVM library by Jarrod Davis which can be found here

https://github.com/tinyBigGAMES/libLLVM

To quote the libllvm readme:

"libLLVM brings the full power of LLVM's compilation infrastructure directly to Delphi, providing native bindings for code generation, optimization, and linking with clean, Pascal-style integration."

This simple calculator project illustrates how one can use libllvm to easily create a high performance llvm backend. Jarrod uses an interesting approach for dealing with the llvm dependency, He stores the llvm Dll as a Delphi resource file which is accessed internally by the executable. This means no separate DLLs need to be deployed with the final executable.
