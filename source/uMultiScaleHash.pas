unit uMultiScaleHash;
{设计总览

┌─────────────────────────────────────────────────────────────┐
│ 通道 A：全局 4096 位 Hash                                    │
│   → 一次性 XOR+PopCount，若汉明距离 > 阈值 → 直接拒绝          │
└─────────────────────────────────────────────────────────────┘
                        │ 通过
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ 通道 B：多尺度分块 Hash（4×4 / 8×8 / 16×16，权重 0.25/0.45/0.30）│
│   ┌── 尺度 s ─────────────────────────────────────────┐      │
│   │ 块级网格 2D 平移 (dy, dx) ∈ [-shiftMax, +shiftMax] │      │
│   │ 每对块：                                          │      │
│   │   PopCount 差 > tol → 跳过                        │      │
│   │   签名汉明距离 > tol → 跳过                        │      │
│   │   XOR + PopCnt → 精确相似度                        │      │
│   └──────────────────────────────────────────────────┘      │
│   各尺度相似度加权平均 → 最终 Similarity                     │
└─────────────────────────────────────────────────────────────┘

}

interface

uses
  System.SysUtils, System.Math, System.Classes, Vcl.Graphics;

const
  MS_IMG_SIZE     = 64;
  MS_SCALE_CNT    = 3;
  MS_BLOCK_SIZES  : array[0..2] of Integer = (4, 8, 16);
  // 需求1：小尺度抓细节、大尺度抓结构，权重按经验调
  MS_WEIGHTS      : array[0..2] of Single  = (0.25, 0.45, 0.30);

  MS_GLOBAL_BITS  = MS_IMG_SIZE * MS_IMG_SIZE;   // 4096
  MS_GLOBAL_BYTES = MS_GLOBAL_BITS div 8;        // 512

  // 需求4：全局快筛阈值（约 25% 位差），宽松以容忍平移
  MS_GLOBAL_HAM_MAX = 1000;

  // 需求3：块级快筛容差
  MS_SIG_HAM_TOL    = 4;   // 8 位签名中不同位 > 4 → 跳过

  // 需求2：块网格平移范围（单位：块）
  MS_SHIFT_MAX_4  = 2;     // 4×4 块 → 16×16 网格，最多平移 2 块 = 8 像素
  MS_SHIFT_MAX_8  = 1;     // 8×8 块 → 8×8 网格，最多平移 1 块 = 8 像素
  MS_SHIFT_MAX_16 = 1;     // 16×16 块 → 4×4 网格，最多平移 1 块 = 16 像素

  // 有效块最小标准差
  MS_STDDEV_MIN = 5.0;

type
  TBlockHash = record
    Words    : array[0..3] of UInt64;  // 最多 4 个 UInt64 = 256 位
    BitCount : Integer;                 // 4×4=16, 8×8=64, 16×16=256
    PopCnt   : Integer;                 // 1 的个数
    Sig      : Byte;                    // 8 位快筛签名
    Valid    : Boolean;                 // 非纯背景
  end;

  TScaleHash = record
    BlockSize : Integer;
    BlockCnt  : Integer;             // 每边块数
    ShiftMax  : Integer;             // 该尺度的网格平移范围
    Blocks    : TArray<TBlockHash>;  // 扁平 BlockCnt²
    ValidCnt  : Integer;
  end;

  TMultiScaleHash = record
    GlobalBits : array[0..MS_GLOBAL_BYTES-1] of Byte;
    GlobalPop  : Integer;
    Scales     : array[0..MS_SCALE_CNT-1] of TScaleHash;
  end;

  TMSMatchResult = record
    Similarity    : Single;
    ScaleSim      : array[0..MS_SCALE_CNT-1] of Single;
    BestRowShift  : array[0..MS_SCALE_CNT-1] of Integer;
    BestColShift  : array[0..MS_SCALE_CNT-1] of Integer;
    GlobalReject  : Boolean;
    GlobalHamDist : Integer;
  end;

procedure BuildMultiScaleHash(bmp: TBitmap; out H: TMultiScaleHash);
function  CompareMultiScaleHash(const A, B: TMultiScaleHash;
  UseGlobalReject: Boolean = True): TMSMatchResult;

implementation

// ---------------- PopCount 基础 ----------------
function PopCount(b: Byte): Integer; inline;
begin
  Result := 0;
  while b <> 0 do
  begin
    Inc(Result, b and 1);
    b := b shr 1;
  end;
end;
function PopCnt64(x: UInt64): Integer; inline;
begin
  {$IF CompilerVersion >= 34}
  Result := {System.Math.}PopCount(x);
  {$ELSE}
  Result := PopCount(Cardinal(x)) + PopCount(Cardinal(x shr 32));
  {$IFEND}
end;

// ---------------- 灰度提取 ----------------
procedure ExtractGray64(bmp: TBitmap; out Gray: TBytes);
var
  tmp: TBitmap;
  x, y, g: Integer;
  p: PByteArray;
begin
  SetLength(Gray, MS_IMG_SIZE * MS_IMG_SIZE);
  tmp := TBitmap.Create;
  try
    tmp.PixelFormat := pf24bit;
    tmp.SetSize(MS_IMG_SIZE, MS_IMG_SIZE);
    tmp.Canvas.StretchDraw(Rect(0, 0, MS_IMG_SIZE, MS_IMG_SIZE), bmp);
    for y := 0 to MS_IMG_SIZE - 1 do
    begin
      p := tmp.ScanLine[y];
      for x := 0 to MS_IMG_SIZE - 1 do
        begin
          g := (p[3*x+2] + p[3*x+1] + p[3*x]) div 3;
          Gray[y*MS_IMG_SIZE + x] := Byte(g);
        end;
    end;
  finally
    tmp.Free;
  end;
end;

// ---------------- 单个块的 Hash ----------------
procedure BuildOneBlock(const Gray: TBytes;
  X0, Y0, BlockSize: Integer; out BH: TBlockHash);
var
  i, j, x, y, g, bitIdx, nBytes: Integer;
  sum, sumSq, mean, variance: Single;
  bitCount: Integer;
  pByt: PByte;
begin
  bitCount := BlockSize * BlockSize;
  BH.BitCount := bitCount;
  BH.Words[0] := 0; BH.Words[1] := 0;
  BH.Words[2] := 0; BH.Words[3] := 0;

  // 均值 + 方差
  sum := 0; sumSq := 0;
  for j := 0 to BlockSize - 1 do
    for i := 0 to BlockSize - 1 do
    begin
      y := Y0 + j; x := X0 + i;
      g := Gray[y*MS_IMG_SIZE + x];
      sum   := sum   + g;
      sumSq := sumSq + g * g;
    end;
  mean := sum / bitCount;
  variance := sumSq / bitCount - mean * mean;
  if variance < 0 then variance := 0;
  BH.Valid := Sqrt(variance) >= MS_STDDEV_MIN;

  // 二值化：MSB 优先
  bitIdx := 0;
  for j := 0 to BlockSize - 1 do
    for i := 0 to BlockSize - 1 do
    begin
      y := Y0 + j; x := X0 + i;
      if Gray[y*MS_IMG_SIZE + x] > mean then
        BH.Words[bitIdx div 64] := BH.Words[bitIdx div 64] or
          (UInt64(1) shl (63 - (bitIdx mod 64)));
      Inc(bitIdx);
    end;

  // PopCount
  BH.PopCnt := 0;
  for i := 0 to (bitCount + 63) div 64 - 1 do
    BH.PopCnt := BH.PopCnt + PopCnt64(BH.Words[i]);

  // 需求3：8 位签名（字节 XOR 折叠）
  BH.Sig := 0;
  nBytes := (bitCount + 7) div 8;
  pByt := PByte(@BH.Words[0]);
  for i := 0 to nBytes - 1 do
    BH.Sig := BH.Sig xor pByt[i];
end;

// ---------------- 构建多尺度 Hash ----------------
procedure BuildMultiScaleHash(bmp: TBitmap; out H: TMultiScaleHash);
var
  Gray: TBytes;
  s, bx, by, idx, nBlocks, bs, i, vc: Integer;
  sumG: Int64;
  meanG: Single;
  shiftArr: array[0..2] of Integer;
begin
  ExtractGray64(bmp, Gray);

  // ===== 通道 A：全局 4096 位 =====
  sumG := 0;
  for i := 0 to MS_IMG_SIZE * MS_IMG_SIZE - 1 do
    sumG := sumG + Gray[i];
  meanG := sumG / (MS_IMG_SIZE * MS_IMG_SIZE);

  FillChar(H.GlobalBits, SizeOf(H.GlobalBits), 0);
  H.GlobalPop := 0;
  for i := 0 to MS_IMG_SIZE * MS_IMG_SIZE - 1 do
    if Gray[i] > meanG then
    begin
      H.GlobalBits[i div 8] := H.GlobalBits[i div 8] or (1 shl (7 - (i mod 8)));
      Inc(H.GlobalPop);
    end;

  // ===== 通道 B：三种尺度 =====
  shiftArr[0] := MS_SHIFT_MAX_4;
  shiftArr[1] := MS_SHIFT_MAX_8;
  shiftArr[2] := MS_SHIFT_MAX_16;

  for s := 0 to MS_SCALE_CNT - 1 do
  begin
    bs := MS_BLOCK_SIZES[s];
    nBlocks := MS_IMG_SIZE div bs;
    H.Scales[s].BlockSize := bs;
    H.Scales[s].BlockCnt  := nBlocks;
    H.Scales[s].ShiftMax  := shiftArr[s];
    SetLength(H.Scales[s].Blocks, nBlocks * nBlocks);

    idx := 0;
    for by := 0 to nBlocks - 1 do
      for bx := 0 to nBlocks - 1 do
      begin
        BuildOneBlock(Gray, bx*bs, by*bs, bs, H.Scales[s].Blocks[idx]);
        Inc(idx);
      end;

    vc := 0;
    for idx := 0 to High(H.Scales[s].Blocks) do
      if H.Scales[s].Blocks[idx].Valid then Inc(vc);
    H.Scales[s].ValidCnt := vc;
  end;
end;

// ---------------- 单对块比较 ----------------
// 返回 True 表示有效比较；Sim 为 0..1
function CompareBlockPair(const A, B: TBlockHash; out Sim: Single): Boolean;
var
  tol, ham, words, i: Integer;
begin
  Result := False;
  Sim := 0;
  if not (A.Valid and B.Valid) then Exit;

  // 需求3：PopCount 快筛（容差按位数比例）
  tol := A.BitCount div 16;
  if tol < 1 then tol := 1;
  if Abs(A.PopCnt - B.PopCnt) > tol then Exit;

  // 需求3：签名快筛
  if PopCount(A.Sig xor B.Sig) > MS_SIG_HAM_TOL then Exit;

  // 精确比较
  words := (A.BitCount + 63) div 64;
  ham := 0;
  for i := 0 to words - 1 do
    ham := ham + PopCnt64(A.Words[i] xor B.Words[i]);

  Sim := (A.BitCount - ham) / A.BitCount;
  Result := True;
end;

// ---------------- 单尺度：带 2D 网格平移 ----------------
function CompareScaleShifted(const SA, SB: TScaleHash;
  out BestRowShift, BestColShift: Integer): Single;
var
  n, dy, dx, row, col, r2, c2, idxA, idxB: Integer;
  minValid, validCnt, bestValidCnt: Integer;
  simSum, bestSim, blockSim: Single;
  ok: Boolean;
begin
  n := SA.BlockCnt;
  BestRowShift := 0;
  BestColShift := 0;
  bestSim := -1;
  bestValidCnt := 0;

  // 两个尺度都需要的有效块数的较小值（用于重叠率判断）
  minValid := Min(SA.ValidCnt, SB.ValidCnt);
  if minValid = 0 then
  begin
    Result := 0;
    Exit;
  end;

  // 需求2：块级网格 2D 平移
  for dy := -SA.ShiftMax to SA.ShiftMax do
    for dx := -SA.ShiftMax to SA.ShiftMax do
    begin
      simSum := 0;
      validCnt := 0;

      for row := 0 to n - 1 do
      begin
        r2 := row + dy;
        if (r2 < 0) or (r2 >= n) then Continue;
        for col := 0 to n - 1 do
        begin
          c2 := col + dx;
          if (c2 < 0) or (c2 >= n) then Continue;

          idxA := row * n + col;
          idxB := r2   * n + c2;

          ok := CompareBlockPair(SA.Blocks[idxA], SB.Blocks[idxB], blockSim);
          if ok then
          begin
            simSum := simSum + blockSim;
            Inc(validCnt);
          end;
        end;
      end;

      // 重叠太少时该移位不可信（避免大位移凑巧高分）
      if validCnt * 2 < minValid then Continue;

      if validCnt > 0 then
      begin
        simSum := simSum / validCnt;
        if simSum > bestSim then
        begin
          bestSim := simSum;
          bestValidCnt := validCnt;
          BestRowShift := dy;
          BestColShift := dx;
        end;
      end;
    end;

  if bestSim < 0 then bestSim := 0;
  Result := bestSim;
end;

// ---------------- 全局 4096 位汉明距离（通道 A）----------------
function GlobalHammingDist(const A, B: TMultiScaleHash): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to MS_GLOBAL_BYTES - 1 do
    Result := Result + PopCount(A.GlobalBits[i] xor B.GlobalBits[i]);
end;

// ---------------- 顶层比较 ----------------
function CompareMultiScaleHash(const A, B: TMultiScaleHash;
  UseGlobalReject: Boolean): TMSMatchResult;
var
  s: Integer;
  rowShift, colShift: Integer;
  scaleSim, totalSim, totalWeight: Single;
begin
  Result.Similarity := 0;
  Result.GlobalReject := False;
  Result.GlobalHamDist := 0;
  for s := 0 to MS_SCALE_CNT - 1 do
  begin
    Result.ScaleSim[s] := 0;
    Result.BestRowShift[s] := 0;
    Result.BestColShift[s] := 0;
  end;

  // ===== 需求4：全局粗筛 =====
  if UseGlobalReject then
  begin
    Result.GlobalHamDist := GlobalHammingDist(A, B);
    if Result.GlobalHamDist > MS_GLOBAL_HAM_MAX then
    begin
      Result.GlobalReject := True;
      Exit;
    end;
  end;

  // ===== 需求1：多尺度加权 =====
  totalSim := 0;
  totalWeight := 0;
  for s := 0 to MS_SCALE_CNT - 1 do
  begin
    scaleSim := CompareScaleShifted(A.Scales[s], B.Scales[s],
                                    rowShift, colShift);
    Result.ScaleSim[s] := scaleSim;
    Result.BestRowShift[s] := rowShift;
    Result.BestColShift[s] := colShift;

    totalSim := totalSim + scaleSim * MS_WEIGHTS[s];
    totalWeight := totalWeight + MS_WEIGHTS[s];
  end;

  if totalWeight > 0 then
    Result.Similarity := totalSim / totalWeight;
end;

end.

(*使用示例

uses uMultiScaleHash;

procedure TForm1.CompareImages;
var
  H1, H2: TMultiScaleHash;
  R: TMSMatchResult;
  s: Integer;
begin
  if (Image2.Picture.Graphic = nil) or (Image5.Picture.Graphic = nil) then Exit;

  // 构建（每张图一次即可，之后可缓存）
  BuildMultiScaleHash(Image2.Picture.Bitmap, H1);
  BuildMultiScaleHash(Image5.Picture.Bitmap, H2);

  // 比较
  R := CompareMultiScaleHash(H1, H2, True);

  Memo1.Lines.Clear;
  if R.GlobalReject then
  begin
    Memo1.Lines.Add(Format('【全局快筛】拒绝：汉明距离 %d / 4096',
      [R.GlobalHamDist]));
    Exit;
  end;

  Memo1.Lines.Add(Format('全局汉明距离 : %d / 4096', [R.GlobalHamDist]));
  Memo1.Lines.Add('');
  for s := 0 to MS_SCALE_CNT - 1 do
    Memo1.Lines.Add(Format('[%2d×%2d] 相似度 %.2f%%  最佳移位 (dy=%d, dx=%d)',
      [MS_BLOCK_SIZES[s], MS_BLOCK_SIZES[s],
       R.ScaleSim[s] * 100, R.BestRowShift[s], R.BestColShift[s]]));
  Memo1.Lines.Add('');
  Memo1.Lines.Add(Format('加权总相似度 : %.2f%%', [R.Similarity * 100]));

  if R.Similarity >= 0.90 then
    Memo1.Lines.Add('判定：同一指纹')
  else if R.Similarity >= 0.80 then
    Memo1.Lines.Add('判定：可能同一指纹')
  else
    Memo1.Lines.Add('判定：不同指纹');
end;


*)
