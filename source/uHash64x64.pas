unit uHash64x64;

interface
uses
  System.SysUtils, System.Math, Vcl.Graphics;

const
  { 8×8 是最平衡的选择：64 位正好用一个 UInt64 就能装下，做位运算时非常方便。}
  IMG_SIZE   = 64;                        // 图像边长
  BLOCK_SIZE = 8;                         // 每块的边长

  BLOCK_CNT  = IMG_SIZE div BLOCK_SIZE;   // 8  (每边 8 块，共 64 块)
  BLOCK_BITS = BLOCK_SIZE * BLOCK_SIZE;   // 64 (每块 64 位)
  STDDEV_MIN = 5.0;                       // 有效块的最小标准差（经验值）

  {
   STDDEV_MIN 是判断"块是否有信息量"的阈值。
   标准差低于它的块视为纯色背景（指纹的空白区域），直接不参与比较。具体数值可以用你自己的样本集调。
  }

type
  TGray64 = array[0..IMG_SIZE-1, 0..IMG_SIZE-1] of Byte;

  TBlockHash = record
    Bits   : string;   // BLOCK_BITS 位，行优先
    Avg    : Single;
    StdDev : Single;
    Valid  : Boolean;  // 是否为"有信息"的块
  end;

  TBlockHashMap = array[0..BLOCK_CNT-1, 0..BLOCK_CNT-1] of TBlockHash;

  TBlockSimResult = record
    //Similarity 反映"整体像不像"
    Similarity   : Single;    // 平均块相似度 (0..1)
    //MatchRate 反映"有多少局部完全对上"
    MatchBlocks  : Integer;   // "几乎完全相同"的块数
    ValidBlocks  : Integer;   // 参与比较的有效块总数
    MatchRate    : Single;    // 完全匹配率
  end;

  function CompareBlockHashWithBitShift(const A, B: TBlockHashMap): TBlockSimResult;

  procedure GetGray64(bmp: TBitmap; out AGray: TGray64);

implementation

procedure GetGray64(bmp: TBitmap; out AGray: TGray64);
var
  p: PByteArray;
  x, y, gray: Integer;
begin
  bmp.PixelFormat := pf24bit;
  for y := 0 to IMG_SIZE - 1 do
  begin
    p := bmp.ScanLine[y];
    for x := 0 to IMG_SIZE - 1 do
    begin
      gray := (p[3*x+2] + p[3*x+1] + p[3*x]) div 3;
      AGray[y, x] := Byte(gray);
    end;
  end;
end;



procedure BuildBlockHashMap(const Gray: TGray64;
  out Map: TBlockHashMap; StdDevMin: Single = STDDEV_MIN);
var
  bx, by, px, py, x, y, idx: Integer;
  sum, sumSq, mean, variance: Single;
begin
  for by := 0 to BLOCK_CNT - 1 do
    for bx := 0 to BLOCK_CNT - 1 do
    begin
      // --- 1. 求该块的均值和标准差 ---
      sum := 0; sumSq := 0;
      for py := 0 to BLOCK_SIZE - 1 do
        for px := 0 to BLOCK_SIZE - 1 do
        begin
          y := by * BLOCK_SIZE + py;
          x := bx * BLOCK_SIZE + px;
          sum   := sum   + Gray[y, x];
          sumSq := sumSq + Gray[y, x] * Gray[y, x];
        end;
      mean := sum / BLOCK_BITS;
      variance := sumSq / BLOCK_BITS - mean * mean;
      if variance < 0 then variance := 0;   // 数值保护

      Map[by, bx].Avg    := mean;
      Map[by, bx].StdDev := Sqrt(variance);
      Map[by, bx].Valid  := Map[by, bx].StdDev >= StdDevMin;

      // --- 2. 与块均值比较，生成 64 位 ---
      SetLength(Map[by, bx].Bits, BLOCK_BITS);
      idx := 1;
      for py := 0 to BLOCK_SIZE - 1 do
        for px := 0 to BLOCK_SIZE - 1 do
        begin
          y := by * BLOCK_SIZE + py;
          x := bx * BLOCK_SIZE + px;
          if Gray[y, x] > mean then
            Map[by, bx].Bits[idx] := '1'
          else
            Map[by, bx].Bits[idx] := '0';
          Inc(idx);
        end;
    end;
end;

function CompareBlockHashSimple(const A, B: TBlockHashMap): TBlockSimResult;
var
  bx, by, i, same, validCnt: Integer;
  simSum, blockSim: Single;
begin  //逐块比较：简单版
  Result.Similarity  := 0;
  Result.MatchBlocks := 0;
  Result.ValidBlocks := 0;
  Result.MatchRate   := 0;

  simSum   := 0;
  validCnt := 0;

  for by := 0 to BLOCK_CNT - 1 do
    for bx := 0 to BLOCK_CNT - 1 do
    begin
      // 两个块都必须"有效"才有意义
      if not (A[by, bx].Valid and B[by, bx].Valid) then
        Continue;

      Inc(validCnt);

      same := 0;
      for i := 1 to BLOCK_BITS do
        if A[by, bx].Bits[i] = B[by, bx].Bits[i] then
          Inc(same);

      blockSim := same / BLOCK_BITS;
      simSum := simSum + blockSim;

      // 该块几乎完全相同，记一票
      if blockSim >= 0.90 then
        Inc(Result.MatchBlocks);
    end;

  Result.ValidBlocks := validCnt;
  if validCnt > 0 then
  begin
    Result.Similarity := simSum / validCnt;
    Result.MatchRate  := Result.MatchBlocks / validCnt;
  end;
end;



function BestBlockSim(const BitsA, BitsB: string): Single;
var
  shift, i, srcIdx, same, bestSame: Integer;
begin
  bestSame := 0;
  for shift := 0 to BLOCK_BITS - 1 do
  begin
    same := 0;
    for i := 1 to BLOCK_BITS do
    begin
      srcIdx := i + shift;
      if srcIdx > BLOCK_BITS then
        srcIdx := srcIdx - BLOCK_BITS;
      if BitsA[i] = BitsB[srcIdx] then
        Inc(same);
    end;
    if same > bestSame then
      bestSame := same;
  end;
  Result := bestSame / BLOCK_BITS;
end;

function CompareBlockHashWithBitShift(const A, B: TBlockHashMap): TBlockSimResult;
var
  bx, by, validCnt: Integer;
  simSum, blockSim: Single;
begin  //逐块比较：带块内位循环移位容错
{
  如果两张图有轻微的局部像素平移，块内逐位比较会掉分。加一层「块内循环移位」就能找回不少。

  代价：每块要试 64 次移位，64 块 × 64 位 × 64 移位 ≈ 26 万次比较/对。Delphi 大约 10~30 ms，完全可以接受。
}
  Result.Similarity  := 0;
  Result.MatchBlocks := 0;
  Result.ValidBlocks := 0;
  Result.MatchRate   := 0;

  simSum   := 0;
  validCnt := 0;

  for by := 0 to BLOCK_CNT - 1 do
    for bx := 0 to BLOCK_CNT - 1 do
    begin
      if not (A[by, bx].Valid and B[by, bx].Valid) then
        Continue;
      Inc(validCnt);

      blockSim := BestBlockSim(A[by, bx].Bits, B[by, bx].Bits);
      simSum := simSum + blockSim;

      if blockSim >= 0.90 then
        Inc(Result.MatchBlocks);
    end;

  Result.ValidBlocks := validCnt;
  if validCnt > 0 then
  begin
    Result.Similarity := simSum / validCnt;
    Result.MatchRate  := Result.MatchBlocks / validCnt;
  end;
end;


(* 完整调用示例

var
  G1, G2: TGray64;
  H1, H2: TBlockHashMap;
  R: TBlockSimResult;
begin
  // 前提：Image2 / Image5 里的图已经是 64×64
  GetGray64(Image2.Picture.Bitmap, G1);
  GetGray64(Image5.Picture.Bitmap, G2);

  BuildBlockHashMap(G1, H1);
  BuildBlockHashMap(G2, H2);

  // ---- 简单逐块比较 ----
  R := CompareBlockHashSimple(H1, H2);
  Memo1.Lines.Add('【简单逐块】');
  Memo1.Lines.Add(Format('平均相似度 : %.2f%%', [R.Similarity * 100]));
  Memo1.Lines.Add(Format('匹配块     : %d / %d  (%.2f%%)',
    [R.MatchBlocks, R.ValidBlocks, R.MatchRate * 100]));

  // ---- 带块内位循环移位 ----
  R := CompareBlockHashWithBitShift(H1, H2);
  Memo1.Lines.Add('【块内位循环移位】');
  Memo1.Lines.Add(Format('平均相似度 : %.2f%%', [R.Similarity * 100]));
  Memo1.Lines.Add(Format('匹配块     : %d / %d  (%.2f%%)',
    [R.MatchBlocks, R.ValidBlocks, R.MatchRate * 100]));

  // ---- 判定 ----
  if (R.Similarity >= 0.90) and (R.MatchRate >= 0.70) then
    Memo1.Lines.Add('判定：同一指纹')
  else if (R.Similarity >= 0.80) and (R.MatchRate >= 0.50) then
    Memo1.Lines.Add('判定：可能同一指纹')
  else
    Memo1.Lines.Add('判定：不同指纹');
end;



*)


end.
