unit Unit1;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.ExtCtrls, Vcl.ExtDlgs, Vcl.Imaging.jpeg, Vcl.StdCtrls,
  Vcl.Menus, dxGDIPlusClasses;

type
  TForm1 = class(TForm)
    Image1: TImage;
    OpenPictureDialog1: TOpenPictureDialog;
    Image2: TImage;
    Image3: TImage;
    Image4: TImage;
    PopupMenu1: TPopupMenu;
    N11: TMenuItem;
    N21: TMenuItem;
    Image5: TImage;
    Image6: TImage;
    Memo1: TMemo;
    Memo2: TMemo;
    Button1: TButton;
    Button2: TButton;
    Button3: TButton;
    Button4: TButton;
    Button5: TButton;
    Button6: TButton;
    Button7: TButton;
    Button8: TButton;
    Button9: TButton;
    Button10: TButton;
    Button11: TButton;
    procedure FormCreate(Sender: TObject);
    procedure bsSkinButton1Click(Sender: TObject);
    procedure bsSkinButton2Click(Sender: TObject);
    procedure bsSkinButton3Click(Sender: TObject);
    procedure N11Click(Sender: TObject);
    procedure N21Click(Sender: TObject);
    procedure Image1DblClick(Sender: TObject);
    procedure Button4Click(Sender: TObject);
    procedure Button5Click(Sender: TObject);
    procedure Button7Click(Sender: TObject);
    procedure Button6Click(Sender: TObject);
    procedure Button8Click(Sender: TObject);
    procedure Button9Click(Sender: TObject);
    procedure Button10Click(Sender: TObject);
    procedure Button11Click(Sender: TObject);
  private
    { Private declarations }
    function Hamming(Hash1, Hash2: Int64): Integer;
    function GetHash(src: TBitmap; iType:Integer = 0): Int64;
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation
uses u32x32_SimilarityTools ,uFingerHash64,uPHash,uGlobalLSHIndex
  ,MyIOUtils;

{$R *.dfm}

function CalcSimilarity(const Bits1, Bits2: string): Single;
var
  i, n, diff: Integer;
begin //直接对字符串逐位比较（最简单，够用）
  n := Length(Bits1);
  if (n = 0) or (n <> Length(Bits2)) then
  begin
    Result := 0;
    Exit;
  end;

  diff := 0;
  for i := 1 to n do
    if Bits1[i] <> Bits2[i] then
      Inc(diff);

  Result := (n - diff) / n;   // 返回 0.0 ~ 1.0
end;

{}

// 把 "1011..." 转成字节数组（每 8 位 1 字节）
function BitsToBytes(const Bits: string): TArray<Byte>;
var
  i, n, b, bit: Integer;
begin
  n := Length(Bits);
  SetLength(Result, (n + 7) div 8);
  for i := 0 to High(Result) do
    Result[i] := 0;              // 初始化，避免随机值

  for i := 1 to n do
  begin
    bit := Ord(Bits[i]) - Ord('0');   // '0' -> 0, '1' -> 1
    b   := (i - 1) div 8;
    Result[b] := (Result[b] shl 1) or Byte(bit);
  end;
end;
// 统计一个字节里 1 的个数（查表或 SWAR）
function PopCount(B: Byte): Integer;
begin
  Result := 0;
  while B <> 0 do
  begin
    Inc(Result, B and 1);
    B := B shr 1;
  end;
end;

function CalcSimilarityFast16(const Bits1, Bits2: string): Single;
var
  a, b: TArray<Byte>;
  i, n, diff: Integer;
begin
  n := Length(Bits1);
  if (n = 0) or (n <> Length(Bits2)) then
  begin
    Result := 0;
    Exit;
  end;

  a := BitsToBytes(Bits1);
  b := BitsToBytes(Bits2);

  diff := 0;
  for i := 0 to High(a) do
    diff := diff + PopCount(a[i] xor b[i]);

  Result := (n - diff) / n;
end;


{}
type
  TSimResult = record
    Similarity : Single;   // 最佳相似度 0.0 ~ 1.0
    RowShift   : Integer;  // 最佳垂直移位量
    ColShift   : Integer;  // 最佳水平移位量
    BitShift   : Integer;  // 最佳整体位循环移位量
  end;

// ---------- 基础：逐位比较 ----------
function SimilarityRaw(const Bits1, Bits2: string): Single;
var
  i, n, same: Integer;
begin
  n := Length(Bits1);
  if (n = 0) or (n <> Length(Bits2)) then
  begin
    Result := 0;
    Exit;
  end;
  same := 0;
  for i := 1 to n do
    if Bits1[i] = Bits2[i] then
      Inc(same);
  Result := same / n;
end;

// ---------- 层1：整体位循环移位 ----------
function SimilarityBitShift(const Bits1, Bits2: string;
  out BestShift: Integer): Single;
var
  n, shift, i, srcIdx, same: Integer;
  best: Single;
begin
  n := Length(Bits1);
  BestShift := 0;
  if (n = 0) or (n <> Length(Bits2)) then
  begin
    Result := 0;
    Exit;
  end;

  best := 0;
  for shift := 0 to n - 1 do
  begin
    same := 0;
    for i := 1 to n do
    begin
      srcIdx := i + shift;
      if srcIdx > n then
        srcIdx := srcIdx - n;
      if Bits1[i] = Bits2[srcIdx] then
        Inc(same);
    end;
    if same / n > best then
    begin
      best := same / n;
      BestShift := shift;
    end;
  end;
  Result := best;
end;

// ---------- 层2 + 层3：按行 / 按列的 2D 循环移位 ----------
// Width = 16（16×16 矩阵），Rows = 16
function Similarity2D(const Bits1, Bits2: string; Width: Integer;
  out BestRowShift, BestColShift: Integer): Single;
var
  n, rows, r, c, srcR, srcC, i1, i2, same: Integer;
  rowShift, colShift: Integer;
  best: Single;
begin
  n := Length(Bits1);
  BestRowShift := 0;
  BestColShift := 0;
  if (n = 0) or (n <> Length(Bits2)) or (Width <= 0) then
  begin
    Result := 0;
    Exit;
  end;
  rows := n div Width;
  if rows = 0 then
  begin
    Result := 0;
    Exit;
  end;

  best := 0;
  for colShift := 0 to Width - 1 do
    for rowShift := 0 to rows - 1 do
    begin
      same := 0;
      for r := 0 to rows - 1 do
      begin
        srcR := (r + rowShift) mod rows;
        for c := 0 to Width - 1 do
        begin
          srcC := (c + colShift) mod Width;
          i1 := r * Width + c + 1;
          i2 := srcR * Width + srcC + 1;
          if Bits1[i1] = Bits2[i2] then
            Inc(same);
        end;
      end;
      if same / n > best then
      begin
        best := same / n;
        BestRowShift := rowShift;
        BestColShift := colShift;
      end;
    end;

  Result := best;
end;

// ---------- 综合：取三种方式中的最大相似度 ----------
function CalcSimilarityEx(const Bits1, Bits2: string;
  Width: Integer = 16): TSimResult;
var
  simRaw, simBit, sim2D: Single;
  bitShift, rowShift, colShift: Integer;
begin
  Result.Similarity := 0;
  Result.RowShift   := 0;
  Result.ColShift   := 0;
  Result.BitShift   := 0;

  if (Length(Bits1) = 0) or (Length(Bits1) <> Length(Bits2)) then
    Exit;

  // 1) 原始逐位
  simRaw := SimilarityRaw(Bits1, Bits2);
  Result.Similarity := simRaw;

  // 2) 整体位循环移位
  simBit := SimilarityBitShift(Bits1, Bits2, bitShift);
  if simBit > Result.Similarity then
  begin
    Result.Similarity := simBit;
    Result.BitShift   := bitShift;
    Result.RowShift   := 0;
    Result.ColShift   := 0;
  end;

  // 3) 2D 行/列循环移位
  sim2D := Similarity2D(Bits1, Bits2, Width, rowShift, colShift);
  if sim2D > Result.Similarity then
  begin
    Result.Similarity := sim2D;
    Result.RowShift   := rowShift;
    Result.ColShift   := colShift;
    Result.BitShift   := 0;
  end;
end;


{}

//图片缩放至 8*8
procedure TForm1.bsSkinButton1Click(Sender: TObject);
var
  bmp: TBitmap;
begin

   Image2.Picture.Graphic:=nil;
   Image3.Picture.Graphic:=nil;
   Image5.Picture.Graphic:=nil;
   Image6.Picture.Graphic:=nil;



  if (Image1.Picture.Graphic=nil) or (Image4.Picture.Graphic=nil) then
  begin
    ShowMessageFmt('%S', ['请先加载图片']);
    Exit;
  end;
  bmp := TBitmap.Create;
  try
    bmp.Width := 8; //8
    bmp.Height := 8; //8
    bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), Image1.Picture.Graphic);
    Image2.Picture.Bitmap.Assign(bmp);
    bmp.FreeImage;
    bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), Image4.Picture.Graphic);
    Image5.Picture.Bitmap.Assign(bmp);
  finally
    bmp.Free;
  end;
end;

procedure TForm1.bsSkinButton2Click(Sender: TObject);
var
  p, p1: PByteArray;
  bmp, bmp1: TBitmap;
  x, y: Integer;
  gray, gray1, sum, sum1: Integer;
  s, s1: string;
  ct: array[0..7, 0..7] of Byte;
  ct1: array[0..7, 0..7] of Byte;
  avg, avg1: Single;
  ret, ret1: Int64;
begin
  if (Image2.Picture.Graphic=nil) or (Image5.Picture.Graphic=nil) then
  begin
    ShowMessage('请先对图像缩放');
    Exit;
  end;
  Memo1.Lines.Clear;
  Memo2.Lines.Clear;

  bmp := TBitmap.Create;
  bmp1 := TBitmap.Create;
  try
    bmp.Assign(Image2.Picture.Bitmap);
    bmp1.Assign(Image5.Picture.Bitmap);
    bmp.PixelFormat := pf24bit;
    bmp1.PixelFormat := TPixelFormat.pf24bit;
    sum := 0; sum1 := 0;
    Memo1.Lines.Add('8*8像素矩阵');
    Memo2.Lines.Add('8*8像素矩阵');
    for y := 0 to 7 do
    begin
      p := bmp.ScanLine[y];
      p1 := bmp1.ScanLine[y];
      s := EmptyStr; s1 := EmptyStr;
      for x := 0 to 7 do
      begin
        //灰度值 平均值法
        gray := (p[3 * x + 2] + p[3 * x + 1] + p[3 * x]) div 3;
        gray1 := (p1[3 * x + 2] + p1[3 * x + 1] + p1[3 * x]) div 3;
        ct[y, x] := gray;
        ct1[y, x] := gray1;
        p[3 * x + 2] := byte(Gray);
        p[3 * x + 1] := byte(Gray);
        p[3 * x] := byte(Gray);
        p1[3 * x + 2] := byte(Gray1);
        p1[3 * x + 1] := byte(Gray1);
        p1[3 * x] := byte(Gray1);
        s := s + IntToStr(gray) + ',';
        s1 := s1 + IntToStr(gray1) + ',';
        sum := sum + gray;
        sum1 := sum1 + gray1;
      end;
      Memo1.Lines.Add(s);
      Memo2.Lines.Add(s1);
    end;
    avg := sum/64;
    avg1 := sum1/64;
    Memo1.Lines.Add('像素平均值');
    Memo1.Lines.Add(FloatToStr(avg));
    Memo2.Lines.Add('像素平均值');
    Memo2.Lines.Add(FloatToStr(avg1));
    ret := 0; ret1 := 0;
    Memo1.Lines.Add('指纹信息矩阵');
    Memo2.Lines.Add('指纹信息矩阵');
    for y := 0 to 7 do
    begin
      s := EmptyStr; s1 := EmptyStr;
      for x := 0 to 7 do
      begin
        if ct[y, x]>avg then
          s := s + '1,'
        else
          s := s + '0,';
        if ct1[y, x]>avg1 then
          s1 := s1 + '1,'
        else
          s1 := s1 + '0,';
        ret := ret shl 1 or Ord(ct[y, x] > avg);
        ret1 := ret1 shl 1 or Ord(ct1[y, x] > avg1);
      end;
      Memo1.Lines.Add(s);
      Memo2.Lines.Add(s1);
    end;
    Memo1.Lines.Add('Hash值');
    Memo1.Lines.Add(IntToStr(ret));
    Memo2.Lines.Add('Hash值');
    Memo2.Lines.Add(IntToStr(ret1));
    Image3.Picture.Bitmap.Assign(bmp);
    Image6.Picture.Bitmap.Assign(bmp1);

    var sim := CalcSimilarity(s, s1);
    Memo1.Lines.Add('相似度: ' + FormatFloat('0.00%', sim));

  finally
    bmp.Free;
  end;
end;


procedure TForm1.bsSkinButton3Click(Sender: TObject);
var
  h1, h2: Int64;
  ham: Integer;
begin
// 值越小相识度越高，10之内可以简单判断这两张图片内容一致

//  Memo1.Lines.Add(IntToStr(Hamming(-216174304209399803, -252203092605396987)));
  h1 := GetHash(Image2.Picture.Bitmap);
  h2 := GetHash(Image5.Picture.Bitmap);
  ham := Hamming(h1, h2);
  Caption := Format('当前两幅图汉明距离为%D', [ham]);
  if ham<10 then
    ShowMessageFmt('%S', ['相似图像'])
  else
    ShowMessageFmt('%S', ['非相似图像']);
end;

procedure TForm1.Button10Click(Sender: TObject);
var
  h1, h2: TPHash64;
  d: Integer;
begin  //两张图比对
  h1 := CalcPHash(Image2.Picture.Bitmap);
  h2 := CalcPHash(Image5.Picture.Bitmap);
  d  := HammingDist64(h1, h2);

  Memo1.Lines.Add(Format('pHash 汉明距离: %d / 64  (相似度 %.2f%%)',
    [d, PHashSimilarity(h1, h2) * 100]));

  // 经验阈值：<= 10 视为可能重复
  if d <= 10 then
    Memo1.Lines.Add('判定：可能是同一张图')
  else
    Memo1.Lines.Add('判定：不同图');
end;

//调用示例（建库 + 查询）
procedure TForm1.Button11Click(Sender: TObject);
var
  Index     : TGlobalLSHIndex;
  Hashes    : TArray<TImageHash64>;
  i, n      : Integer;
  G         : TGray64Arr;
  QueryHash : TImageHash64;
  bestIdx   : Integer;
  bestSim   : Single;
  imgLoader:TImage;
  imgFiles:TStrings;
begin
  imgLoader:=TImage.Create(nil);

  imgFiles:=TStringList.Create;

  // ---------- 1. 建库 ----------
  var picPath:='D:\yang\projects\罗为\以图搜图工具\以图搜图测试数据\以图搜图测试\图库';
  MyIOUtils.FindFiles(picPath,imgFiles,'*.jpg');

  Index := TGlobalLSHIndex.Create;
  var bmp := TBitmap.Create;
   try
    SetLength(Hashes, imgFiles.Count);
    for I := 0 to imgFiles.Count-1 do
    begin
       imgLoader.Picture.LoadFromFile(imgFiles[i]);

      bmp.Width := 64;
      bmp.Height := 64;
      bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), imgLoader.Picture.Graphic);
      Image2.Picture.Bitmap.FreeImage;
      Image2.Picture.Bitmap.Assign(bmp);
      GetGray64(Image2.Picture.Bitmap, G);
      BuildImageHash64(G, Hashes[i]);
      bmp.FreeImage;
    end;  //for i end
  finally
    bmp.Free;
  end;

  Index.AddHashes(Hashes);
  Memo1.Lines.Add(Format('已入库 %d 张，4 张 LSH 表建好', [Index.Count]));

  freeandnil(imgFiles);

  try

    // ---------- 2. 查询 ----------
    GetGray64(Image5.Picture.Bitmap, G);
    BuildImageHash64(G, QueryHash);

    bestSim:=0.0;

    if Index.QueryBest(QueryHash, bestIdx, bestSim) then
      Memo1.Lines.Add(Format('最佳匹配: #%d, 相似度 %.2f%%',
        [bestIdx, bestSim * 100]))
    else
      Memo1.Lines.Add('库中没有匹配项');

    // ---------- 3. 想看候选数量 ----------
    Memo1.Lines.Add(Format('LSH 候选数: %d / %d',
      [Length(Index.QueryCandidates(QueryHash)), Index.Count]));

  finally
    imgLoader.Free;
    Index.Free;
  end;
end;

procedure TForm1.Button4Click(Sender: TObject);
var
  bmp: TBitmap;
begin

   Image2.Picture.Graphic:=nil;
   Image3.Picture.Graphic:=nil;
   Image5.Picture.Graphic:=nil;
   Image6.Picture.Graphic:=nil;


  if (Image1.Picture.Graphic=nil) or (Image4.Picture.Graphic=nil) then
  begin
    ShowMessageFmt('%S', ['请先加载图片']);
    Exit;
  end;
  bmp := TBitmap.Create;
  try
    bmp.Width := 16;
    bmp.Height := 16;
    bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), Image1.Picture.Graphic);
    Image2.Picture.Bitmap.Assign(bmp);
    bmp.FreeImage;
    bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), Image4.Picture.Graphic);
    Image5.Picture.Bitmap.Assign(bmp);
  finally
    bmp.Free;
  end;
end;


procedure TForm1.Button5Click(Sender: TObject);
var
  p, p1: PByteArray;
  bmp, bmp1: TBitmap;
  x, y: Integer;
  gray, gray1, sum, sum1: Integer;
  s, s1, bits, bits1: string;
  ct: array[0..15, 0..15] of Byte;
  ct1: array[0..15, 0..15] of Byte;
  avg, avg1: Single;

  // 将二进制位串按每 4 位打包成 1 位十六进制字符
  function BitsToHex(const Bits: string): string;
  var
    i, j, v, n: Integer;
  begin
    Result := '';
    n := Length(Bits);
    i := 1;
    while i <= n do
    begin
      v := 0;
      for j := 0 to 3 do
      begin
        v := v shl 1;
        if (i + j <= n) and (Bits[i + j] = '1') then
          v := v or 1;
      end;
      Result := Result + IntToHex(v, 1);
      Inc(i, 4);
    end;
  end;

begin

{
 对比两张图的相似度：
 现在可以直接比较 bits 与 bits1 相同位的个数，除以 256 得到相似度，
 这比 8×8 时更精确。


 阈值选择：
 指纹这类图像，经验上 8×8（64位）阈值约 85%~90%；
 16×16（256位）因为位数多，阈值一般取 90%~95% 比较合适，
 具体要看你自己的样本集去调。

}


  if (Image2.Picture.Graphic = nil) or (Image5.Picture.Graphic = nil) then
  begin
    ShowMessage('请先对图像缩放');
    Exit;
  end;
  Memo1.Lines.Clear;
  Memo2.Lines.Clear;

  bmp := TBitmap.Create;
  bmp1 := TBitmap.Create;
  try
    bmp.Assign(Image2.Picture.Bitmap);
    bmp1.Assign(Image5.Picture.Bitmap);
    bmp.PixelFormat := pf24bit;
    bmp1.PixelFormat := pf24bit;

    sum := 0;
    sum1 := 0;
    Memo1.Lines.Add('16*16像素矩阵');
    Memo2.Lines.Add('16*16像素矩阵');

    // ---------- 第一步：求 16x16 灰度矩阵 ----------
    for y := 0 to 15 do
    begin
      p  := bmp.ScanLine[y];
      p1 := bmp1.ScanLine[y];
      s  := EmptyStr;
      s1 := EmptyStr;
      for x := 0 to 15 do
      begin
        // 灰度值 平均值法
        gray  := (p[3 * x + 2]  + p[3 * x + 1]  + p[3 * x])  div 3;
        gray1 := (p1[3 * x + 2] + p1[3 * x + 1] + p1[3 * x]) div 3;

        ct[y, x]  := gray;
        ct1[y, x] := gray1;

        // 回写灰度图（预览用）
        p[3 * x + 2]  := Byte(gray);
        p[3 * x + 1]  := Byte(gray);
        p[3 * x]      := Byte(gray);
        p1[3 * x + 2] := Byte(gray1);
        p1[3 * x + 1] := Byte(gray1);
        p1[3 * x]     := Byte(gray1);

        s  := s  + IntToStr(gray)  + ',';
        s1 := s1 + IntToStr(gray1) + ',';

        sum  := sum  + gray;
        sum1 := sum1 + gray1;
      end;
      Memo1.Lines.Add(s);
      Memo2.Lines.Add(s1);
    end;

    // ---------- 第二步：像素平均值（16*16 = 256） ----------
    avg  := sum  / 256;
    avg1 := sum1 / 256;
    Memo1.Lines.Add('像素平均值');
    Memo1.Lines.Add(FloatToStr(avg));
    Memo2.Lines.Add('像素平均值');
    Memo2.Lines.Add(FloatToStr(avg1));

    // ---------- 第三步：指纹信息矩阵 + Hash ----------
    bits  := '';
    bits1 := '';
    Memo1.Lines.Add('指纹信息矩阵');
    Memo2.Lines.Add('指纹信息矩阵');

    for y := 0 to 15 do
    begin
      s  := EmptyStr;
      s1 := EmptyStr;
      for x := 0 to 15 do
      begin
        if ct[y, x] > avg then
        begin
          s := s + '1,';
          bits := bits + '1';
        end
        else
        begin
          s := s + '0,';
          bits := bits + '0';
        end;

        if ct1[y, x] > avg1 then
        begin
          s1 := s1 + '1,';
          bits1 := bits1 + '1';
        end
        else
        begin
          s1 := s1 + '0,';
          bits1 := bits1 + '0';
        end;
      end;
      Memo1.Lines.Add(s);
      Memo2.Lines.Add(s1);
    end;

    // ---------- 第四步：输出 Hash ----------
    Memo1.Lines.Add('Hash值(十六进制, 64字符)');
    Memo1.Lines.Add(BitsToHex(bits));
    Memo2.Lines.Add('Hash值(十六进制, 64字符)');
    Memo2.Lines.Add(BitsToHex(bits1));

    // 如果还想看纯二进制位串，可以再输出：
    // Memo1.Lines.Add(bits);
    // Memo2.Lines.Add(bits1);

    Image3.Picture.Bitmap.Assign(bmp);
    Image6.Picture.Bitmap.Assign(bmp1);



 //  var sim := CalcSimilarity(bits, bits1);
     var sim := CalcSimilarityFast16(bits, bits1);

     Memo1.Lines.Add('相似度: ' + FormatFloat('0.0000%', sim));
     Memo1.Lines.Add('汉明距离: ' + IntToStr(Round((1 - sim) * Length(bits))));

     if sim >= 0.949 then
      Memo1.Lines.Add('判定：极相似（同一指纹）')
    else if sim >= 0.849 then
      Memo1.Lines.Add('判定：较相似')
    else
      Memo1.Lines.Add('判定：不相似');




    {
    var res := CalcSimilarityEx(bits, bits1, 16);

    Memo1.Lines.Add('--------------------------------');
    Memo1.Lines.Add('原始相似度(逐位)    : ' +
      FormatFloat('0.00%', SimilarityRaw(bits, bits1)));
    Memo1.Lines.Add('最佳容错相似度      : ' +
      FormatFloat('0.00%', res.Similarity));
    Memo1.Lines.Add('最佳位循环移位量    : ' + IntToStr(res.BitShift));
    Memo1.Lines.Add('最佳垂直移位(行)    : ' + IntToStr(res.RowShift));
    Memo1.Lines.Add('最佳水平移位(列)    : ' + IntToStr(res.ColShift));

    // 判定
    if res.Similarity >= 0.949 then
      Memo1.Lines.Add('判定：极相似（同一指纹）')
    else if res.Similarity >= 0.849 then
      Memo1.Lines.Add('判定：较相似')
    else
      Memo1.Lines.Add('判定：不相似');
    }





  finally
    bmp.Free;
    bmp1.Free;   // 原代码漏了释放 bmp1，这里补上
  end;
end;

procedure TForm1.Button6Click(Sender: TObject);
var
  bmp: TBitmap;
begin

   Image2.Picture.Graphic:=nil;
   Image3.Picture.Graphic:=nil;
   Image5.Picture.Graphic:=nil;
   Image6.Picture.Graphic:=nil;


  if (Image1.Picture.Graphic=nil) or (Image4.Picture.Graphic=nil) then
  begin
    ShowMessageFmt('%S', ['请先加载图片']);
    Exit;
  end;
  bmp := TBitmap.Create;
  try
    bmp.Width := 32;
    bmp.Height := 32;
    bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), Image1.Picture.Graphic);
    Image2.Picture.Bitmap.Assign(bmp);
    bmp.FreeImage;
    bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), Image4.Picture.Graphic);
    Image5.Picture.Bitmap.Assign(bmp);
  finally
    bmp.Free;
  end;
end;

procedure TForm1.Button7Click(Sender: TObject);
const
  GRID = 32;   // 改成 16 就是 16×16，改成 32 就是 32×32   改成 64 就是 64×64

type
  TGrayMatrix = array[0..GRID-1, 0..GRID-1] of Byte;

var
  p, p1: PByteArray;
  bmp, bmp1: TBitmap;
  x, y: Integer;
  gray, gray1, sum, sum1: Integer;
  s, s1, bits, bits1: string;
  ct, ct1: TGrayMatrix;
  avg, avg1: Single;

function BitsToHex(const Bits: string): string;
var
  i, j, v, n: Integer;
begin
  Result := '';
  n := Length(Bits);
  i := 1;
  while i <= n do
  begin
    v := 0;
    for j := 0 to 3 do
    begin
      v := v shl 1;
      if (i + j <= n) and (Bits[i + j] = '1') then
        v := v or 1;
    end;
    Result := Result + IntToHex(v, 1);
    Inc(i, 4);
  end;
end;

begin
   Memo1.Lines.Clear;
  Memo2.Lines.Clear;

   Memo1.Lines.Add('【'+FormatDateTime('hh:mm:ss:zzz',now)+'】开始');

  if (Image2.Picture.Graphic = nil) or (Image5.Picture.Graphic = nil) then
  begin
    ShowMessage('请先对图像缩放');
    Exit;
  end;

  bmp := TBitmap.Create;
  bmp1 := TBitmap.Create;
  try
    bmp.Assign(Image2.Picture.Bitmap);
    bmp1.Assign(Image5.Picture.Bitmap);
    bmp.PixelFormat  := pf24bit;
    bmp1.PixelFormat := pf24bit;

    sum  := 0;
    sum1 := 0;
  //  Memo1.Lines.Add(Format('%d*%d像素矩阵', [GRID, GRID]));
  //  Memo2.Lines.Add(Format('%d*%d像素矩阵', [GRID, GRID]));

    // ---------- 1. 灰度矩阵 ----------
    for y := 0 to GRID - 1 do
    begin
      p  := bmp.ScanLine[y];
      p1 := bmp1.ScanLine[y];
      s  := EmptyStr;
      s1 := EmptyStr;
      for x := 0 to GRID - 1 do
      begin
        gray  := (p[3*x+2]  + p[3*x+1]  + p[3*x])  div 3;
        gray1 := (p1[3*x+2] + p1[3*x+1] + p1[3*x]) div 3;

        ct[y, x]  := gray;
        ct1[y, x] := gray1;

        p[3*x+2]  := Byte(gray);   p[3*x+1]  := Byte(gray);   p[3*x]  := Byte(gray);
        p1[3*x+2] := Byte(gray1);  p1[3*x+1] := Byte(gray1);  p1[3*x] := Byte(gray1);

        s  := s  + IntToStr(gray)  + ',';
        s1 := s1 + IntToStr(gray1) + ',';

        sum  := sum  + gray;
        sum1 := sum1 + gray1;
      end;
    //  Memo1.Lines.Add(s);
    //  Memo2.Lines.Add(s1);
    end;

    // ---------- 2. 平均值 ----------
    avg  := sum  / (GRID * GRID);
    avg1 := sum1 / (GRID * GRID);

    {Memo1.Lines.Add('像素平均值');
    Memo1.Lines.Add(FloatToStr(avg));
    Memo2.Lines.Add('像素平均值');
    Memo2.Lines.Add(FloatToStr(avg1));
    }
    // ---------- 3. 指纹位串 ----------
    bits  := '';
    bits1 := '';
    SetLength(bits,  GRID * GRID);
    SetLength(bits1, GRID * GRID);

    var idx: Integer := 1;
  //  Memo1.Lines.Add('指纹信息矩阵');
  //  Memo2.Lines.Add('指纹信息矩阵');
    for y := 0 to GRID - 1 do
    begin
      s  := EmptyStr;
      s1 := EmptyStr;
      for x := 0 to GRID - 1 do
      begin
        if ct[y, x] > avg then
        begin
          s := s + '1,';   bits[idx] := '1';
        end
        else
        begin
          s := s + '0,';   bits[idx] := '0';
        end;

        if ct1[y, x] > avg1 then
        begin
          s1 := s1 + '1,'; bits1[idx] := '1';
        end
        else
        begin
          s1 := s1 + '0,'; bits1[idx] := '0';
        end;

        Inc(idx);
      end;
     // Memo1.Lines.Add(s);
     // Memo2.Lines.Add(s1);
    end;

    // ---------- 4. Hash ----------
  {  Memo1.Lines.Add(Format('Hash值(十六进制, %d字符)', [GRID*GRID div 4]));
    Memo1.Lines.Add(BitsToHex(bits));
    Memo2.Lines.Add(Format('Hash值(十六进制, %d字符)', [GRID*GRID div 4]));
    Memo2.Lines.Add(BitsToHex(bits1));

    Image3.Picture.Bitmap.Assign(bmp);
    Image6.Picture.Bitmap.Assign(bmp1);
   }

    {}
    var sim :single:=0.000;
    var BestShift:integer:=0;
    if GRID=32 then
     sim := u32x32_SimilarityTools.SimilarityFast32(bits, bits1,BestShift)
    else
     sim := CalcSimilarityFast16(bits, bits1);


     Memo1.Lines.Add('【'+FormatDateTime('hh:mm:ss:zzz',now)+'】结束');

     Memo1.Lines.Add('相似度: ' + FormatFloat('0.0000%', sim));
     Memo1.Lines.Add('汉明距离: ' + IntToStr(Round((1 - sim) * Length(bits))));

     if sim >= 0.929 then
      Memo1.Lines.Add('判定：极相似（同一指纹）')
    else if sim >= 0.829 then
      Memo1.Lines.Add('判定：较相似')
    else
      Memo1.Lines.Add('判定：不相似');



  finally
    bmp.Free;
    bmp1.Free;
  end;
end;

procedure TForm1.Button8Click(Sender: TObject);
var
  bmp: TBitmap;
begin
   Image2.Picture.Graphic:=nil;
   Image3.Picture.Graphic:=nil;
   Image5.Picture.Graphic:=nil;
   Image6.Picture.Graphic:=nil;

  if (Image1.Picture.Graphic=nil) or (Image4.Picture.Graphic=nil) then
  begin
    ShowMessageFmt('%S', ['请先加载图片']);
    Exit;
  end;
  bmp := TBitmap.Create;
  try
    bmp.Width := 64;
    bmp.Height := 64;
    bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), Image1.Picture.Graphic);
    Image2.Picture.Bitmap.Assign(bmp);
    bmp.FreeImage;
    bmp.Canvas.StretchDraw(Rect(0, 0, bmp.Width, bmp.Height), Image4.Picture.Graphic);
    Image5.Picture.Bitmap.Assign(bmp);
  finally
    bmp.Free;
  end;
end;

procedure TForm1.Button9Click(Sender: TObject);
var
  G1, G2: TGray64Arr;
  H1, H2: TImageHash64;
  R: TMatchResult64;
begin
  Memo1.Lines.Add('【'+FormatDateTime('hh:mm:ss:zzz',now)+'】开始');
  // 1. 前提：Image2 / Image5 已是 64×64 图像
  GetGray64(Image2.Picture.Bitmap, G1);
  GetGray64(Image5.Picture.Bitmap, G2);

  // 2. 构建分块 Hash
  BuildImageHash64(G1, H1);
  BuildImageHash64(G2, H2);

  // 3. 比较
  R := CompareImageHash64(H1, H2, True);

  Memo1.Lines.Add('【'+FormatDateTime('hh:mm:ss:zzz',now)+'】结束');

  // 4. 输出
 // Memo1.Lines.Clear;
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
  Memo1.Lines.Add('H1.ImageSig='+H1.ImageSig.ToString+sLineBreak+'H2.ImageSig='+H2.ImageSig.ToString);

  Memo1.Lines.Add('【'+FormatDateTime('hh:mm:ss:zzz',now)+'】结束2');
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  Self.Position := TPosition(4);
  Image1.Stretch := True;
  Image4.Stretch := True;
end;


function TForm1.GetHash(src: TBitmap; iType: Integer): Int64;
var
  p: PByteArray;
  bmp: TBitmap;
  x, y: Integer;
  gray, sum: Integer;
  ct: array[0..7, 0..7] of Byte;
  avg: Single;
  ret: Int64;
begin
  ret := 0;
  case iType of
    0:  // aHash  平均哈希算法
    begin
      bmp := TBitmap.Create;
      try
        bmp.Assign(src);
        bmp.Width := 8;
        bmp.Height := 8;
        bmp.PixelFormat := pf24bit;
        sum := 0;
        for y := 0 to 7 do
        begin
          p := bmp.ScanLine[y];
          for x := 0 to 7 do
          begin
            //转灰度图 平均值法
            gray := (p[3 * x + 2] + p[3 * x + 1] + p[3 * x]) div 3;
            ct[y, x] := gray;
            sum := sum + gray;
          end;
        end;
        avg := sum/64;
        for y := 0 to 7 do
          for x := 0 to 7 do
            ret := ret shl 1 or Ord(ct[y, x] > avg);
      finally
        bmp.Free;
      end;
    end;
    1:  // pHash  感知哈希算法
    begin

    end;
    2:  // dHash  差异哈希算法
    begin

    end;
  end;
  Result := ret;
end;

function TForm1.Hamming(Hash1, Hash2: Int64): Integer;
var
  A: Int64;
begin
  Result := 0;
  //参考：https://blog.csdn.net/u013243347/article/details/52220551
  A := Hash1 xor Hash2;
  while A<>0 do
  begin
    A := A and (A-1);
    Inc(Result);
  end;
end;

procedure TForm1.Image1DblClick(Sender: TObject);
begin
//OpenPictureDialog1
end;

procedure TForm1.N11Click(Sender: TObject);
begin
  with OpenPictureDialog1 do
  begin
    Filter := 'Jpeg File(*.jpg)|*.jpg|PNG File(*.png)|*.png|Bitmaps(*.bmp)|*.bmp';
    if Execute then
    begin
      if FilterIndex = 0 then
        Image1.Picture.Graphic.LoadFromFile(FileName)
      else
        Image1.Picture.LoadFromFile(FileName);
    end;
  end;
end;

procedure TForm1.N21Click(Sender: TObject);
begin
  with OpenPictureDialog1 do
  begin
    Filter := 'Jpeg File(*.jpg)|*.jpg|PNG File(*.png)|*.png|Bitmaps(*.bmp)|*.bmp';
    if Execute then
    begin
      if FilterIndex = 0 then
        Image4.Picture.Graphic.LoadFromFile(FileName)
      else
        Image4.Picture.LoadFromFile(FileName);
    end;
  end;
end;

end.
