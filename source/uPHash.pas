unit uPHash;
{
整图 pHash（DCT 低频二值化）的 Delphi 实现
pHash 的核心是：
  把图像缩到 32×32 灰度 → 做二维 DCT → 取左上角 8×8 低频系数 → 二值化成 64 位。
  这个 64 位对 JPEG 重压缩、轻微缩放、亮度变化都非常鲁棒，正好作为 LSH 的第一层粗筛。

为什么要 32×32 输入？
只取 8×8 低频系数，输入必须大于 8×8。
32×32 是业界常用尺寸，DCT 计算量适中，抗噪能力也够。
}

interface

uses
  System.SysUtils, System.Math, System.Classes, Vcl.Graphics;

const
  PHASH_DCT_SIZE = 32;   // DCT 输入尺寸
  PHASH_LOW      = 8;    // 取低频 8×8

type
  TPHash64 = UInt64;

// 从 TBitmap 直接计算 pHash
function CalcPHash(bmp: TBitmap): TPHash64;

// 汉明距离（pHash 相似度用）
function HammingDist64(a, b: TPHash64): Integer; inline;

// 便捷：两个 pHash 的相似度（0..1）
function PHashSimilarity(a, b: TPHash64): Single; inline;

{}

// 辅助：UInt64 转 64 位二进制串
function UIntToBin(v: UInt64): string;


{}
implementation

{}

// 辅助：UInt64 转 64 位二进制串
function UIntToBin(v: UInt64): string;
var
  i: Integer;
begin
  SetLength(Result, 64);
  for i := 0 to 63 do
    Result[64 - i] := Chr(Ord('0') + ((v shr i) and 1));
end;



{}

var
  // 预计算余弦表：cos((2n+1)·k·π / (2N))，只算前 8 个 k
  CosTbl  : array[0..PHASH_LOW-1, 0..PHASH_DCT_SIZE-1] of Double;
  CosReady: Boolean = False;

procedure EnsureCosTable;
var
  k, n: Integer;
begin
  if CosReady then Exit;
  for k := 0 to PHASH_LOW-1 do
    for n := 0 to PHASH_DCT_SIZE-1 do
      CosTbl[k, n] := Cos((2*n + 1) * k * Pi / (2 * PHASH_DCT_SIZE));
  CosReady := True;
end;

// ---------- 提取 32×32 灰度 ----------
procedure ExtractGray32(bmp: TBitmap; var Gray: array of Byte);
var
  tmp : TBitmap;
  x, y, g: Integer;
  p   : PByteArray;
begin
  tmp := TBitmap.Create;
  try
    tmp.PixelFormat := pf24bit;
    tmp.SetSize(PHASH_DCT_SIZE, PHASH_DCT_SIZE);
    tmp.Canvas.StretchDraw(
      Rect(0, 0, PHASH_DCT_SIZE, PHASH_DCT_SIZE), bmp);

    for y := 0 to PHASH_DCT_SIZE-1 do
    begin
      p := tmp.ScanLine[y];
      for x := 0 to PHASH_DCT_SIZE-1 do
      begin
        g := (p[3*x+2] + p[3*x+1] + p[3*x]) div 3;
        Gray[y*PHASH_DCT_SIZE + x] := Byte(g);
      end;
    end;
  finally
    tmp.Free;
  end;
end;

// ---------- 1D DCT-II：输出前 K 个系数 ----------
// X[k] = Σ_{n=0}^{N-1} x[n] · cos((2n+1)·k·π / (2N))
procedure DCT1D(const Input: array of Double; aK: Integer;
  var Output: array of Double);
var
  k, n: Integer;
  sum : Double;
begin
  for k := 0 to aK-1 do
  begin
    sum := 0;
    for n := 0 to PHASH_DCT_SIZE-1 do
      sum := sum + Input[n] * CosTbl[k, n];
    Output[k] := sum;
  end;
end;

// ---------- 核心：计算 pHash ----------
function CalcPHash(bmp: TBitmap): TPHash64;
var
  Gray    : array[0..PHASH_DCT_SIZE*PHASH_DCT_SIZE-1] of Byte;
  RowIn   : array[0..PHASH_DCT_SIZE-1] of Double;
  RowOut  : array[0..PHASH_LOW-1] of Double;
  ColIn   : array[0..PHASH_DCT_SIZE-1] of Double;
  ColOut  : array[0..PHASH_LOW-1] of Double;

  // 第一步 DCT 结果（32 行 × 8 列）
  RowCoeff: array[0..PHASH_DCT_SIZE-1, 0..PHASH_LOW-1] of Double;
  // 最终 8×8 系数
  Coeff   : array[0..PHASH_LOW-1, 0..PHASH_LOW-1] of Double;

  x, y, i, j, bitIdx: Integer;
  sum, mean: Double;
  bits: UInt64;
begin
  EnsureCosTable;
  ExtractGray32(bmp, Gray);

  // ========== 1. 行方向 DCT ==========
  for y := 0 to PHASH_DCT_SIZE-1 do
  begin
    for x := 0 to PHASH_DCT_SIZE-1 do
      RowIn[x] := Gray[y*PHASH_DCT_SIZE + x];
    DCT1D(RowIn, PHASH_LOW, RowOut);
    for i := 0 to PHASH_LOW-1 do
      RowCoeff[y, i] := RowOut[i];
  end;

  // ========== 2. 列方向 DCT ==========
  for i := 0 to PHASH_LOW-1 do
  begin
    for y := 0 to PHASH_DCT_SIZE-1 do
      ColIn[y] := RowCoeff[y, i];
    DCT1D(ColIn, PHASH_LOW, ColOut);
    for j := 0 to PHASH_LOW-1 do
      Coeff[j, i] := ColOut[j];
  end;

  // ========== 3. 求均值（排除 DC） ==========
  sum := 0;
  for i := 0 to PHASH_LOW-1 do
    for j := 0 to PHASH_LOW-1 do
      if not ((i = 0) and (j = 0)) then
        sum := sum + Coeff[i, j];
  mean := sum / (PHASH_LOW*PHASH_LOW - 1);   // 除以 63

  // ========== 4. 二值化 → 64 位 ==========
  bits   := 0;
  bitIdx := 63;
  for i := 0 to PHASH_LOW-1 do
    for j := 0 to PHASH_LOW-1 do
    begin
      if Coeff[i, j] > mean then
        bits := bits or (UInt64(1) shl bitIdx);
      Dec(bitIdx);
    end;

  Result := bits;
end;

function PopCount(b: Byte): Integer;inline;
begin
  Result := 0;
  while b <> 0 do
  begin
    Inc(Result, b and 1);
    b := b shr 1;
  end;
end;

// ---------- 汉明距离 ----------
function HammingDist64(a, b: TPHash64): Integer;
begin
//  {$IF CompilerVersion >= 34}
 // Result :={ System.Math.}PopCount(a xor b);
 // {$ELSE}
  Result := PopCount(Cardinal(a xor b))
          + PopCount(Cardinal((a xor b) shr 32));
 // {$IFEND}
end;

function PHashSimilarity(a, b: TPHash64): Single;
begin
  Result := (64 - HammingDist64(a, b)) / 64;
end;

end.
