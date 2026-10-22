unit u32x32_SimilarityTools;

interface

// 快速相似度（只做整体位循环移位）
function SimilarityFast32(const Bits1, Bits2: string; out BestShift: Integer): Single;

implementation


{ 性能升级：位运算版（强烈推荐用于 32×32 批量场景）
  如果要批量比对成百上千张，就用该版本
 }

type
  TBitPack = record
    Data : TArray<Byte>;   // 每字节 8 位
    Bits : Integer;        // 有效位数
  end;

// 字符串 -> 字节打包
function PackBits(const Bits: string): TBitPack;
var
  i, b, bit: Integer;
begin
  Result.Bits := Length(Bits);
  SetLength(Result.Data, (Result.Bits + 7) div 8);
  for i := 0 to High(Result.Data) do
    Result.Data[i] := 0;

  for i := 1 to Result.Bits do
  begin
    bit := Ord(Bits[i]) - Ord('0');
    if bit <> 0 then
      Result.Data[(i-1) div 8] := Result.Data[(i-1) div 8] or (1 shl (7 - ((i-1) mod 8)));
  end;
end;

// 统计一个字节里 1 的个数（查表法）
{const
  PopTbl: array[0..255] of Byte = (
    // 也可用循环生成，这里省略，用算法代替
  ); }

function PopCount(b: Byte): Integer;
begin
  Result := 0;
  while b <> 0 do
  begin
    Inc(Result, b and 1);
    b := b shr 1;
  end;
end;

// 汉明距离（字节级）
function HammingBits(const A, B: TBitPack): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(A.Data) do
    Result := Result + PopCount(A.Data[i] xor B.Data[i]);
end;

// 按字节循环右移
function RotateRightBytes(const Src: TBitPack; ShiftBits: Integer): TBitPack;
var
  nBytes, byteShift, bitShift, i, srcIdx: Integer;
  carry, nextCarry: Byte;
begin
  Result.Bits := Src.Bits;
  nBytes := Length(Src.Data);
  SetLength(Result.Data, nBytes);

  byteShift := (ShiftBits div 8) mod nBytes;
  bitShift  := ShiftBits mod 8;

  for i := 0 to nBytes - 1 do
  begin
    srcIdx := (i + byteShift) mod nBytes;
    if bitShift = 0 then
      Result.Data[i] := Src.Data[srcIdx]
    else
      Result.Data[i] :=
        (Src.Data[srcIdx] shr bitShift) or
        (Src.Data[(srcIdx + 1) mod nBytes] shl (8 - bitShift));
  end;
end;

// 快速相似度（只做整体位循环移位）
function SimilarityFast32(const Bits1, Bits2: string; out BestShift: Integer): Single;
var
  a, b, t: TBitPack;
  n, shift, diff, bestDiff: Integer;
begin
  a := PackBits(Bits1);
  b := PackBits(Bits2);
  n := a.Bits;
  BestShift := 0;
  if (n = 0) or (n <> b.Bits) then
  begin
    Result := 0;
    Exit;
  end;

  bestDiff := n;
  for shift := 0 to n - 1 do
  begin
    t := RotateRightBytes(b, shift);
    diff := HammingBits(a, t);
    if diff < bestDiff then
    begin
      bestDiff := diff;
      BestShift := shift;
    end;
  end;
  Result := (n - bestDiff) / n;
end;

end.
