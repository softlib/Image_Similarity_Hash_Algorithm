unit uGlobalLSHIndex;
{
LSH 思路：把每个 Hash 的若干"局部特征"做成桶 key，只有命中同一桶的候选才需要精确比较。

建库时：每个图算好 Hash，把它的若干个 key 插入对应的桶。

查询时：算 Query 的 key，从对应的桶里捞出候选（去重），只对这些候选做精确比较。

关键：
   LSH 是「近似」的，可能漏掉真匹配。
   为了把召回率拉回来，用多张 LSH 表 + 多段 key + 投票合并。

}

interface
uses
  System.SysUtils, System.Math, Vcl.Graphics,system.generics.collections
  ,uFingerHash64;

const
  LSH_TABLE_COUNT = 4;    // 4 张表
  LSH_KEY_BITS    = 16;   // 每张表用 16 位做 key

type
  // 单个桶：存图片在库里的下标
  TIdList = TArray<Integer>;

  // 4 张 LSH 表
  TLSHTable = array[0..LSH_TABLE_COUNT-1] of TDictionary<UInt16, TIdList>;

  // 全局索引
  TGlobalLSHIndex = class
  private
    FTables : TLSHTable;
    FHashes : TArray<TImageHash64>;
    FCount  : Integer;
  public
    constructor Create;
    destructor  Destroy; override;

    // 批量入库
    procedure AddHashes(const Hashes: TArray<TImageHash64>);

    // 查询：返回可能匹配的候选下标（去重后）
    function  QueryCandidates(const Query: TImageHash64): TIdList;

    // 查询 + 精确比较，一步到位
    function  QueryBest(const Query: TImageHash64;
      out BestIdx: Integer; out BestSim: Single): Boolean;

    property  Count: Integer read FCount;
    property  Hashes: TArray<TImageHash64> read FHashes;
  end;

implementation
uses dialogs;


  // 从 ImageSig 提取第 k 段 16 位
function ExtractLSHKey(const Sig: UInt64; TableIdx: Integer): UInt16; inline;
begin
  Result := UInt16((Sig shr (TableIdx * LSH_KEY_BITS)) and $FFFF);
end;


{ TGlobalLSHIndex }

constructor TGlobalLSHIndex.Create;
var
  i: Integer;
begin
  inherited;
  for i := 0 to LSH_TABLE_COUNT-1 do
    FTables[i] := TDictionary<UInt16, TIdList>.Create;
  FCount := 0;
end;

destructor TGlobalLSHIndex.Destroy;
var
  i: Integer;
begin
  for i := 0 to LSH_TABLE_COUNT-1 do
    FTables[i].Free;
  inherited;
end;

procedure TGlobalLSHIndex.AddHashes(const Hashes: TArray<TImageHash64>);
var
  i, t, n, oldN: Integer;
  key: UInt16;
  list: TIdList;
begin
  n := Length(Hashes);
  if n = 0 then Exit;

  // 追加到 FHashes
  oldN := Length(FHashes);
  SetLength(FHashes, oldN + n);
  for i := 0 to n-1 do
    FHashes[oldN + i] := Hashes[i];

  // 插入 4 张 LSH 表
  for i := 0 to n-1 do
  begin
    for t := 0 to LSH_TABLE_COUNT-1 do
    begin
      key := ExtractLSHKey(Hashes[i].ImageSig, t);
      if not FTables[t].TryGetValue(key, list) then
      begin
        SetLength(list, 0);
        FTables[t].Add(key, list);
      end;
      SetLength(list, Length(list) + 1);
      list[High(list)] := oldN + i;
      FTables[t].AddOrSetValue(key, list);
    end;
  end;

  FCount := Length(FHashes);
end;

function TGlobalLSHIndex.QueryCandidates(
  const Query: TImageHash64): TIdList;
var
  t, i, id: Integer;
  key: UInt16;
  list: TIdList;
  seen: TDictionary<Integer, Byte>;
begin
  seen := TDictionary<Integer, Byte>.Create;
  try
    for t := 0 to LSH_TABLE_COUNT-1 do
    begin
      key := ExtractLSHKey(Query.ImageSig, t);

      if FTables[t].TryGetValue(key, list) then
      begin
       // showmessage('len(list)='+Length(list).ToString);


        for i := 0 to High(list) do
        begin
          id := list[i];
          if not seen.ContainsKey(id) then
            seen.Add(id, 1);
        end;
      end;
    end;

    Result := seen.Keys.ToArray;
  finally
    seen.Free;
  end;
end;

function TGlobalLSHIndex.QueryBest(const Query: TImageHash64;
  out BestIdx: Integer; out BestSim: Single): Boolean;
var
  cands: TIdList;
  i, idx: Integer;
  r: TMatchResult64;
begin
  BestIdx := -1;
  BestSim := 0;
  Result  := False;

  cands := QueryCandidates(Query);
 // showmessage('len(cands)='+Length(cands).ToString);
  for i := 0 to High(cands) do
  begin
    idx := cands[i];
    r := CompareImageHash64(Query, FHashes[idx], True);
    if r.FastRejected then Continue;

    if r.Similarity > BestSim then
    begin
      BestSim := r.Similarity;
      BestIdx := idx;
      Result  := True;
    end;
  end;
end;



end.
