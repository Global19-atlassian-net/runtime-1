// Copyright 2020 The TensorFlow Runtime Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//===- basic_kernels.td ---------------------------------------------------===//
//
// Operation definitions for basic_kernels.
//
//===----------------------------------------------------------------------===//

#ifdef BASIC_OPS
#else
#define BASIC_OPS

include "tfrt/basic_kernels/opdefs/tfrt_base.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

// Base class for TFRT dialect ops.
class TFRT_Op<string mnemonic, list<OpTrait> traits = []> :
    Op<TFRT_Dialect, mnemonic, !listconcat(traits, [IsolatedFromAbove])> {

  // Each registered op in the TFRT namespace needs to provide all of a printer,
  // parser and verifier.
  let printer = [{ return tfrt::print(p, *this); }];
  let verifier = [{ return tfrt::verify(*this); }];
  let parser = [{ return tfrt::parse$cppClass(parser, result); }];
}

def CallOp : TFRT_Op<"call"> {
  let summary = "host executor call operation";
  let description = [{
    The "tfrt.call" operation represents a direct call to a function.  The
    operands and result types of the call must match the specified function
    type.  The callee is encoded as a function attribute named "callee".

      %2 = tfrt.call @my_add(%0, %1) : (f32, f32) -> f32
  }];

  let arguments = (ins FlatSymbolRefAttr:$callee, Variadic<AnyType>:$operands);
  let results = (outs Variadic<AnyType>);

  let extraClassDeclaration = [{
    StringRef getCallee() { return callee(); }
    mlir::FunctionType getCalleeType();
  }];
}

class ConstantOp<string suffix, Type baseType, Attr attr>
  : TFRT_Op<"constant." # suffix, [NoSideEffect]> {
  let summary = "host executor constant value constructor";

  let arguments = (ins attr:$value);
  let results = (outs baseType);
}

def ConstantI1Op  : ConstantOp<"i1", I1, I1Attr>;
def ConstantI32Op : ConstantOp<"i32", I32, I32Attr>;
def ConstantI64Op : ConstantOp<"i64", I64, I64Attr>;
def ConstantF32Op : ConstantOp<"f32", F32, F32Attr>;
def ConstantF64Op : ConstantOp<"f64", F64, F64Attr>;

def IfOp : TFRT_Op<"if"> {
  let summary = "if operation";
  let description = [{
    The "tfrt.if" operation takes an i1 condition, a 'then' body and an 'else'
    body.  If the condition is true, the 'then' body is run and the "tfrt.if"
    operation returns the results of that region, otherwise the "else" body is
    run and its values are returned.

    The body regions must have the same signature, but they may take an
    arbitrary number of arguments and return values with the same types as the
    op return types, using a 'tfrt.return' operation at the end of the
    region.  The initial values are specified as operands of "tfrt.if" (along
    with the condition), and the types of the values are specified with a
    function type.

    This operation is safe to use as a 'nonstrict' op, which dispatches its body
    whenever the condition and any dependent arguments are resolved.

    Example:

      %res = tfrt.if %cond, %x, %y : (i32, f32) -> i32 {
        %v1 = "use"(%x, %y) : (i32, f32) -> i32
        tfrt.return %v1 : i32
      } else {
        %v2 = "abuse"(%x, %y) : (i32, f32) -> i32
        tfrt.return %v2 : i32
      }
  }];
  let arguments = (ins I1:$cond, Variadic<AnyType>);
  let results = (outs Variadic<AnyType>);
  let regions = (region SizedRegion<1>:$then_region,
                        SizedRegion<1>:$else_region);
}

def CondOp : TFRT_Op<"cond"> {
  let summary = "conditional operation";
  let description = [{
    The "tfrt.cond" operation takes an i1 condition, a 'true' function and a
    'false' function.  If the condition is true, the 'true' function is called
    and the "tfrt.cond" operation returns the results of that function, otherwise
    the "false" function is called and its values are returned.

    The 'true' and 'false' functions must have the same signature, but they may
    take an arbitrary number of arguments and return values with the same types
    as the op return types. Both functions are encoded as function attribute,
    named true_fn and false_fn. The a_ and b_ prefix prevent reordering by BEF
    since BEF orders attribute by name alphabetically.

    This operation is safe to use as a 'nonstrict' op, which dispatches its body
    whenever the condition and any dependent arguments are resolved.

    Example:

      %res = tfrt.cond %cond @true_fn @false_fn (%x, %y) : (i32, f32) -> (i32)
  }];
  let arguments = (ins I1:$cond,
                       FlatSymbolRefAttr:$a_true_fn,
                       FlatSymbolRefAttr:$b_false_fn,
                       Variadic<AnyType>:$fn_operands);
  let results = (outs Variadic<AnyType>:$outputs);

  let assemblyFormat = [{
    $cond $a_true_fn $b_false_fn `(` $fn_operands `)` attr-dict `:` `(` type($fn_operands) `)` `->` `(` type($outputs) `)`
  }];
}

def NewChainOp : TFRT_Op<"new.chain", [NoSideEffect]> {
  let summary = "host executor chain constructor";
  let description = [{
    The "tfrt.new.chain" operation returns a !tfrt.chain value, which can be fed
    into a side-effecting operation that does not depend on anything.
    For example:

      func @foo() {
        ...
        %x = tfrt.new.chain
        "side.effecting.thing"(%x) : (!tfrt.chain) -> ()
      }
  }];

  let arguments = (ins);
  let results = (outs TFRT_ChainType);
  let assemblyFormat = "attr-dict";
  let verifier = ?;
}

def MergeChainsOp : TFRT_Op<"merge.chains", [NoSideEffect]> {
  let summary = "host executor merge chain";
  let description = [{
    The "tfrt.merge.chains" operation merges variadic number of !tfrt.chain inputs
    and outputs a single !tfrt.chain output.

    Example:

        %c1 = tfrt.new.chain
        %c2 = tfrt.new.chain
        %c3 = tfrt.new.chain
        %merged_c = tfrt.merge.chains %c1, %c2, %c3
  }];

  let arguments = (ins Variadic<TFRT_ChainType>:$chains);
  let results = (outs TFRT_ChainType);
  let assemblyFormat = "$chains attr-dict";
  let verifier = ?;
}

def RepeatI32Op : TFRT_Op<"repeat.i32"> {
  let summary = "repeat.i32 operation";
  let description = [{
    The "tfrt.repeat.i32" operation is a repeat loop that executes its body N
    times, where N is a 32-bit value specified by its first operand.  It has one
    region which represents the loop body.

    The body region takes an arbitrary number of arguments and must return
    values with the same types, using a 'tfrt.return' operation at the end of the
    region.  The initial values for the loop are specified as operands (along
    with the trip count), and the types of the loop values are specified with a
    type list.  The operation returns the results of the final iteration.

    This operation is safe to use as a 'nonstrict' op, which dispatches its body
    whenever dependent arguments are resolved.

    Example:

      %res1, %res2 = tfrt.repeat.i32 %i, %loopval1, %loopval2 : i32, f32 {
        "use"(%loopval1, %loopval2) : (i32, f32) -> ()
        ...
        tfrt.return %loopval1, %loopval2 : i32, f32
      }
  }];
  let arguments = (ins I32:$trip_count, Variadic<AnyType>);
  let results = (outs Variadic<AnyType>);
  let regions = (region SizedRegion<1>:$region);
}

def ParallelForI32Op : TFRT_Op<"parallel_for.i32"> {
  let summary = "parallel_for.i32 operation";
  let description = [{
    The "tfrt.parallel_for.i32" operation is a parallel for loop that executes
    its body function for non overlapping sub ranges. It has one region which
    represents the loop body function (see host_context/parallel_for.h C++
    equivalent).

    The body region takes an arbitrary number of arguments and must return a
    single chain value using a 'tfrt.return' operation at the end of the region
    if it completes asynchronously. If the body region completes synchronously
    it must have empty returns (`tfrt.return` without operands).

    Inside the loop region `%start` and `%end` values are bound to the parallel
    block start and end offsets (see example below).

    This is a TFRT counterpart of the native C++ ParallelFor operation defined
    in: `host_context/parallel_for.h`.

    Example:

      %from       = tfrt.constant.i32 0
      %to         = tfrt.constant.i32 100
      %block_size = tfrt.constant.i32 10

      %val = ... : !my.type

      %done = tfrt.parallel_for.i32 %from to %to fixed %block_size,
                                   %val : !my.type {
        // Possible values for [%start, %end) are: [0, 10), [10, 20), ...
        "use"(%start, %end, %val) : (i32, i32, !my.type) -> ()

        // Async regions must return a chain to signal completion.
        tfrt.return %chain : !tfrt.chain

        // Sync regions must have an empty return.
        tfrt.return
      }
  }];
  let arguments = (ins I32:$start, I32:$end, I32:$block_size,
                   Variadic<AnyType>);
  let results = (outs Variadic<AnyType>);
  let regions = (region SizedRegion<1>:$region);
}

def ParallelCallI32Op : TFRT_Op<"parallel_call.i32"> {
  let summary = "parallel_call.i32 operation";
  let description = [{
    The "tfrt.parallel_call.i32" is an alternative to "tfrt.parallel_for.i32" with
    a parallel region defined as a standalone function.

    Example:

      func @compute(%start : i32, %end : i32, %val : !my_type) -> !tfrt.chain {
        ...
      }

      %from       = tfrt.constant.i32 0
      %to         = tfrt.constant.i32 100
      %block_size = tfrt.constant.i32 10

      %val = ... : !my.type

      %done = tfrt.parallel_call.i32 %from to %to fixed %block_size
              @compute(%val) : !my.type
  }];

  let arguments = (ins FlatSymbolRefAttr:$callee,
                   I32:$start, I32:$end, I32:$block_size,
                   Variadic<AnyType>:$operands);
  let results = (outs Variadic<AnyType>);
}

def ReturnOp : TFRT_Op<"return", [Terminator]> {
  let summary = "host executor return operation";
  let description = [{
    The "tfrt.return" operation represents a return operation within a function.
    The operation takes variable number of operands and produces no results.
    The operand number and types must match the signature of the function
    that contains the operation. For example:

      func @foo() : (i32, f8) {
        ...
        tfrt.return %0, %1 : i32, f8
  }];

  let arguments = (ins Variadic<AnyType>:$operands);

  let builders = [OpBuilder<
    "OpBuilder &b, OperationState &result", [{ build(b, result, llvm::None); }]
  >];
}

class AddOp<string suffix, Type type>
  : TFRT_Op<"add." # suffix, [NoSideEffect]> {
  let summary = "tfrt.add operation";
  let description = [{
     An operation that takes two inputs and returns their sum as the result.

     Example:
       %2 = tfrt.add.i32 %0, %1
  }];
  let arguments = (ins type, type);
  let results = (outs type);
  let assemblyFormat = "operands attr-dict";
  let verifier = ?;
}

def AddI32Op : AddOp<"i32", I32>;
def AddI64Op : AddOp<"i64", I64>;
def AddF32Op : AddOp<"f32", F32>;
def AddF64Op : AddOp<"f64", F64>;

class AndOp<string suffix, Type type>
  : TFRT_Op<"and." # suffix, [NoSideEffect]> {
  let summary = "tfrt.and operation";
  let description = [{
     An operation that takes two inputs and returns their conjunction as the
     result.

     Example:
       %2 = tfrt.and.i1 %0, %1
  }];
  let arguments = (ins type, type);
  let results = (outs type);
  let assemblyFormat = "operands attr-dict";
  let verifier = ?;
}

def AndI1Op : AndOp<"i1", I1>;

class EqualOp<string suffix, Type type>
  : TFRT_Op<"equal." # suffix, [NoSideEffect]> {
  let summary = "tfrt.equal operation";
  let description = [{
     An operation that takes two inputs and returns their equality as the
     result.

     Example:
       %2 = tfrt.equal.i32 %0, %1
  }];
  let arguments = (ins type, type);
  let results = (outs I1);
  let assemblyFormat = "operands attr-dict";
  let verifier = ?;
}

def EqualI32Op : EqualOp<"i32", I32>;
def EqualI64Op : EqualOp<"i64", I64>;

class DivOp<string suffix, Type type>
  : TFRT_Op<"div." # suffix, [NoSideEffect]> {
  let summary = "tfrt.div operation";
  let description = [{
     An operation that takes two inputs and returns their quotient and remainder
     as the result.

     Example:
       %2, %3 = tfrt.div.i32 %0, %1
  }];
  let arguments = (ins type, type);
  let results = (outs type, type);
  let assemblyFormat = "operands attr-dict";
  let verifier = ?;
}

def DivI32Op : DivOp<"i32", I32>;
def DivI64Op : DivOp<"i64", I64>;

class PrintOp<string suffix, Type type> : TFRT_Op<"print." # suffix> {
  let summary = "tfrt.print operation";
  let description = [{
     An operation takes a number input and a chain input.
     It prints the number to stdout and returns a chain output.
     The chain input must be the second operand.

     Example:
       %2 = tfrt.print.i32 %0, %1
  }];
  let arguments = (ins type, TFRT_ChainType);
  let results = (outs TFRT_ChainType);
  let assemblyFormat = "operands attr-dict";
  let verifier = ?;
}

def PrintI1Op : PrintOp<"i1", I1>;
def PrintI32Op : PrintOp<"i32", I32>;
def PrintI64Op : PrintOp<"i64", I64>;
def PrintF32Op : PrintOp<"f32", F32>;
def PrintF64Op : PrintOp<"f64", F64>;

#endif  // BASIC_OPS
