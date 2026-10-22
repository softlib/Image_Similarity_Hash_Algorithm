unit uFingerHash64;
{
 8×8 块 UInt64 位运算加速版 + 块级快筛
一、设计要点
1、每个 8×8 块 = 64 位 = 一个 UInt64：比较只需要 XOR + PopCount（现代 CPU 各 1 条指令）。

2、块级快筛：每块再算 1 字节签名（8 个字节 XOR），比较前先比签名，汉明距离过大直接跳过 PopCount。

3、整图快筛：8 个行签名打包成 1 个 UInt64，批量比对时先比它，能一次性拒掉大部分候选。

4、量级估计：相比字符串逐位比较，单对比较快 50~100 倍；加上整图快筛，批量场景再快 5~10 倍。

}

interface

uses
  System.SysUtils, System.Math, Vcl.Graphics;

const
  H64_GRID       = 64;                          // 图像 64×64
  H64_BLK_CNT    = 8;                           // 每边 8 个块
  H64_BLK_SIZE   = 8;                           // 每块 8×8
  H64_STDDEV_MIN = 5.0;                         // 有效块的最小标准差

  //块级跳过阈值
  H64_SIG_HAM_HIGH = 7;   // 块签名汉明距离 >= 6 → 视为不匹配，跳过 PopCount
  //整图拒绝阈值
  H64_IMG_HAM_MAX  = 40;  // 整图签名汉明距离 > 40 → 整图拒绝

type
  TGray64Arr = array[0..H64_GRID * H64_GRID - 1] of Byte;

  TBlockHash64 = record
    Bits : UInt64;   // 64 位指纹
    Sig  : Byte;     // 8 位快筛签名
    Valid: Boolean;  // 有效块（非纯背景）
  end;

  TImageHash64 = record
    Blocks  : array[0..H64_BLK_CNT-1, 0..H64_BLK_CNT-1] of TBlockHash64;
    ImageSig: UInt64;   // 8 个行签名打包（每字节一个行签名）
    ValidBlk: Integer;  // 有效块数量
  end;

  TMatchResult64 = record
    Similarity  : Single;   // 平均块相似度
    MatchBlocks : Integer;  // 几乎完全匹配的块数
    ValidBlocks : Integer;  // 参与比较的有效块数
    MatchRate   : Single;   // 完全匹配率
    FastRejected: Boolean;  // 是否被整图快筛提前拒绝
  end;

// 从 TBitmap 提取 64×64 灰度
procedure GetGray64(bmp: TBitmap; out Gray: TGray64Arr);

// 构建 64×64 分块 Hash
procedure BuildImageHash64(const Gray: TGray64Arr; out H: TImageHash64;
  StdDevMin: Single = H64_STDDEV_MIN);

// 单对比较
function CompareImageHash64(const A, B: TImageHash64;
  UseFastReject: Boolean = True): TMatchResult64;

// 批量比较：把 Query 与 Candidates 逐一比对
procedure BatchCompare64(const Query: TImageHash64;
  const Candidates: TArray<TImageHash64>;
  out Results: TArray<TMatchResult64>;
  UseFastReject: Boolean=true);

implementation

// 统计一个字节里 1 的个数（查表法）
{const
  PopTbl: array[0..255] of Byte = (
    // 也可用循环生成，这里省略，用算法代替
  ); }

function PopCount(b: Byte): Integer; inline;
begin
  Result := 0;
  while b <> 0 do
  begin
    Inc(Result, b and 1);
    b := b shr 1;
  end;
end;

// ---------- 内联 PopCount（64 位） ----------
function PopCnt64(x: UInt64): Integer; inline;
begin
  {$IF CompilerVersion >= 34}  // Delphi 10.4+
  Result := {System.Math.}PopCount(x);
  {$ELSE}
  Result := PopCount(Cardinal(x)) + PopCount(Cardinal(x shr 32));
  {$IFEND}
end;

// ---------- 64 位值的 8 字节 XOR 签名 ----------
function ByteXorSig(x: UInt64): Byte; inline;
var
//absolute 关键字的妙用：p: array[0..7] of Byte absolute x; 让 UInt64 与 8 字节数组共用同一内存，零开销取字节。
  p: array[0..7] of Byte absolute x;
begin
  Result := p[0] xor p[1] xor p[2] xor p[3]
         xor p[4] xor p[5] xor p[6] xor p[7];
end;

// ---------- 从 Bitmap 提取 64×64 灰度 ----------
procedure GetGray64(bmp: TBitmap; out Gray: TGray64Arr);
var
  x, y, g: Integer;
  p: PByteArray;
begin
  bmp.PixelFormat := pf24bit;
  for y := 0 to H64_GRID - 1 do
  begin
    p := bmp.ScanLine[y];
    for x := 0 to H64_GRID - 1 do
    begin
      g := (p[3*x+2] + p[3*x+1] + p[3*x]) div 3;
      Gray[y*H64_GRID + x] := Byte(g);
    end;
  end;
end;

// ---------- 构建 64×64 分块 Hash ----------
procedure BuildImageHash64(const Gray: TGray64Arr; out H: TImageHash64;
  StdDevMin: Single);
var
  by, bx, py, px, y, x, bitIdx, validCount: Integer;
  sum, sumSq, mean, variance, stddev: Single;
  bits, bitMask: UInt64;
  sig: Byte;
  rowXors: array[0..7] of Byte;
  rowXor: Byte;
begin
  validCount := 0;
  for by := 0 to H64_BLK_CNT-1 do
  begin
    rowXor := 0;
    for bx := 0 to H64_BLK_CNT-1 do
    begin
      // ---- 均值 & 标准差 ----
      sum := 0; sumSq := 0;
      for py := 0 to H64_BLK_SIZE-1 do
        for px := 0 to H64_BLK_SIZE-1 do
        begin
          y := by*H64_BLK_SIZE + py;
          x := bx*H64_BLK_SIZE + px;
          sum   := sum   + Gray[y*H64_GRID + x];
          sumSq := sumSq + Gray[y*H64_GRID + x] * Gray[y*H64_GRID + x];
        end;
      mean := sum / 64;
      variance := sumSq/64 - mean*mean;
      if variance < 0 then variance := 0;
      stddev := Sqrt(variance);

      // ---- 与块均值比较 → 64 位 ----
      bits := 0;
      bitIdx := 63;
      for py := 0 to H64_BLK_SIZE-1 do
        for px := 0 to H64_BLK_SIZE-1 do
        begin
          y := by*H64_BLK_SIZE + py;
          x := bx*H64_BLK_SIZE + px;
          if Gray[y*H64_GRID + x] > mean then
          begin
            bitMask := UInt64(1) shl bitIdx;
            bits := bits or bitMask;
          end;
          Dec(bitIdx);
        end;

      sig := ByteXorSig(bits);

      H.Blocks[by, bx].Bits  := bits;
      H.Blocks[by, bx].Sig   := sig;
      H.Blocks[by, bx].Valid := stddev >= StdDevMin;

      if H.Blocks[by, bx].Valid then
        Inc(validCount);

      rowXor := rowXor xor sig;
    end;
    rowXors[by] := rowXor;
  end;

  // 8 个行签名打包成一个 UInt64
  H.ImageSig := UInt64(rowXors[0])
             or (UInt64(rowXors[1]) shl 8)
             or (UInt64(rowXors[2]) shl 16)
             or (UInt64(rowXors[3]) shl 24)
             or (UInt64(rowXors[4]) shl 32)
             or (UInt64(rowXors[5]) shl 40)
             or (UInt64(rowXors[6]) shl 48)
             or (UInt64(rowXors[7]) shl 56);

  H.ValidBlk := validCount;
end;

// ---------- 单对比较：带整图 + 块级快筛 ----------
function CompareImageHash64(const A, B: TImageHash64;
  UseFastReject: Boolean): TMatchResult64;
var
  by, bx, validCnt, matchBlocks: Integer;
  simSum, blockSim: Single;
  xorVal: UInt64;
  same: Integer;
  sigHam: Integer;
begin
  Result.Similarity   := 0;
  Result.MatchBlocks  := 0;
  Result.ValidBlocks  := 0;
  Result.MatchRate    := 0;
  Result.FastRejected := False;

  // ================= 第一层：整图快筛 =================
  if UseFastReject then
  begin
    if PopCnt64(A.ImageSig xor B.ImageSig) > H64_IMG_HAM_MAX then
    begin
      Result.FastRejected := True;
      Exit;  // 完全不同的图，直接拒绝
    end;
  end;

  simSum      := 0;
  validCnt    := 0;
  matchBlocks := 0;

  // ================= 第二层：逐块比较 =================
  for by := 0 to H64_BLK_CNT-1 do
    for bx := 0 to H64_BLK_CNT-1 do
    begin
      if not (A.Blocks[by,bx].Valid and B.Blocks[by,bx].Valid) then
        Continue;
      Inc(validCnt);

      // ---- 块级快筛：签名差距过大 → 跳过 PopCount ----
      if UseFastReject then
      begin
        sigHam := PopCount(A.Blocks[by,bx].Sig xor B.Blocks[by,bx].Sig);
        if sigHam >= H64_SIG_HAM_HIGH then
          Continue;  // 该块 0 分，省下 XOR + PopCount
      end;

      // ---- 精确比较：单条 XOR + 单条 POPCNT ----
      xorVal  := A.Blocks[by,bx].Bits xor B.Blocks[by,bx].Bits;
      same    := 64 - PopCnt64(xorVal);
      blockSim := same / 64;

      simSum := simSum + blockSim;
      if blockSim >= 0.90 then
        Inc(matchBlocks);
    end;

  Result.ValidBlocks := validCnt;
  if validCnt > 0 then
  begin
    Result.Similarity  := simSum / validCnt;
    Result.MatchBlocks := matchBlocks;
    Result.MatchRate   := matchBlocks / validCnt;
  end;
end;

// ---------- 批量比较 ----------
procedure BatchCompare64(const Query: TImageHash64;
  const Candidates: TArray<TImageHash64>;
  out Results: TArray<TMatchResult64>;
  UseFastReject: Boolean);
var
  i: Integer;
begin
  SetLength(Results, Length(Candidates));
  for i := 0 to High(Candidates) do
    Results[i] := CompareImageHash64(Query, Candidates[i], UseFastReject);
end;

end.

(*调用示例

uses
  uFingerHash64;

procedure TForm1.CompareFingerprints;
var
  G1, G2: TGray64Arr;
  H1, H2: TImageHash64;
  R: TMatchResult64;
begin
  // 1. 前提：Image2 / Image5 已是 64×64 图像
  GetGray64(Image2.Picture.Bitmap, G1);
  GetGray64(Image5.Picture.Bitmap, G2);

  // 2. 构建分块 Hash
  BuildImageHash64(G1, H1);
  BuildImageHash64(G2, H2);

  // 3. 比较
  R := CompareImageHash64(H1, H2, True);

  // 4. 输出
  Memo1.Lines.Clear;
  if R.FastRejected then
  begin
    Memo1.Lines.Add('【整图快筛】直接拒绝：两图差异过大');
    Exit;
  end;

  Memo1.Lines.Add(Format('平均相似度 : %.2f%%', [R.Similarity * 100]));
  Memo1.Lines.Add(Format('匹配块     : %d / %d  (%.2f%%)',
    [R.MatchBlocks, R.ValidBlocks, R.MatchRate * 100]));

  if (R.Similarity >= 0.90) and (R.MatchRate >= 0.70) then
    Memo1.Lines.Add('判定：同一指纹')
  else if (R.Similarity >= 0.80) and (R.MatchRate >= 0.50) then
    Memo1.Lines.Add('判定：可能同一指纹')
  else
    Memo1.Lines.Add('判定：不同指纹');
end;


*)

(*批量比对示例（1 对 N）

procedure TForm1.BatchMatch;
var
  QueryHash : TImageHash64;
  Candidates: array of TImageHash64;
  Results   : array of TMatchResult64;
  i, bestIdx: Integer;
  bestSim   : Single;
  G: TGray64Arr;
begin
  // 1. 准备 Query
  GetGray64(Image2.Picture.Bitmap, G);
  BuildImageHash64(G, QueryHash);

  // 2. 准备 N 个候选（假设 Bitmap 存在某 List 中）
  SetLength(Candidates, CandidateCount);
  for i := 0 to CandidateCount - 1 do
  begin
    GetGray64(CandidateBitmaps[i], G);
    BuildImageHash64(G, Candidates[i]);
  end;

  // 3. 一次批量比较（快筛自动生效）
  BatchCompare64(QueryHash, Candidates, Results, True);

  // 4. 找出最佳匹配
  bestIdx := -1;
  bestSim := 0;
  for i := 0 to High(Results) do
  begin
    if Results[i].FastRejected then
      Continue;  // 被整图快筛拒了，跳过
    if Results[i].Similarity > bestSim then
    begin
      bestSim := Results[i].Similarity;
      bestIdx := i;
    end;
  end;

  if bestIdx >= 0 then
    Memo1.Lines.Add(Format('最佳匹配 #%d, 相似度 %.2f%%',
      [bestIdx, bestSim * 100]))
  else
    Memo1.Lines.Add('全部候选都被快筛拒绝');
end;

*)
