program Project1;

uses
  Vcl.Forms,
  Unit1 in 'Unit1.pas' {Form1},
  u32x32_SimilarityTools in 'u32x32_SimilarityTools.pas',
  uFingerHash64 in 'uFingerHash64.pas',
  uPHash in 'uPHash.pas',
  uGlobalLSHIndex in 'uGlobalLSHIndex.pas',
  uHash64x64 in 'uHash64x64.pas',
  uMultiScaleHash in 'uMultiScaleHash.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
