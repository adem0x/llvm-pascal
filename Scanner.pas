unit Scanner;
{
Author: Wanderlan Santos dos Anjos, wanderlan.anjos@gmail.com
Date: jan-2010
License: <extlink http://www.opensource.org/licenses/bsd-license.php>BSD</extlink>
}
interface

uses
  Classes;

type
  TTokenKind = (tkUndefined, tkIdentifier, tkStringConstant, tkCharConstant, tkIntegerConstant, tkRealConstant, tkConstantExpression,
                tkLabelIdentifier, tkTypeIdentifier, tkClassIdentifier, tkReservedWord, tkSpecialSymbol);
  TToken = class
    Lexeme       : string;
    Kind         : TTokenKind;
    RealValue    : Extended;
    IntegerValue : Int64;
  end;
  TSetChar = set of char;
  TScanner = class
  private
    Arq       : text;
    FToken    : TToken;
    LenLine   : integer;
    FInitTime : TDateTime;
    Macros    : TStringList;
    FSourceName, Line : string;
    FStartComment : string[10];
    FEndComment   : string[100];
    procedure NextChar(C : TSetChar);
    procedure FindEndComment(const StartComment, EndComment : shortstring);
    procedure SetFSourceName(const Value : string);
    procedure DoDirective(DollarInc : integer);
    procedure SkipBlank; inline;
    function TokenIn(const S : string) : boolean; inline;
    procedure NextString;
    procedure DoIf(Condition : boolean);
    procedure CreateMacro;
  protected
    FEndSource : boolean;
    FLineNumber, FTotalLines, First, FErrors, FMaxErrors, Top, LastGoodTop : integer;
    NestedIf : shortstring;
    ReservedWords : string;
    function CharToTokenKind(N : char) : TTokenKind;
    function TokenKindToChar(T : TTokenKind) : char;
    function GetNonTerminalName(N : char) : string;
    procedure ScanChars(const Chars: array of TSetChar; const Tam : array of integer; Optional : boolean = false);
    procedure NextToken(Skip : boolean = false);
    procedure RecoverFromError(const Expected, Found : string); virtual;
  public
    constructor Create(MaxErrors : integer = 10);
    destructor Destroy; override;
    procedure Error(const Msg : string); virtual;
    procedure MatchToken(const TokenExpected : string);
    procedure MatchTerminal(KindExpected : TTokenKind);
    property SourceName : string    read FSourceName write SetFSourceName;
    property LineNumber : integer   read FLineNumber;
    property TotalLines : integer   read FTotalLines;
    property ColNumber  : integer   read First;
    property Token      : TToken    read FToken;
    property EndSource  : boolean   read FEndSource;
    property Errors     : integer   read FErrors;
    property InitTime   : TDateTime read FInitTime;
  end;

implementation

uses
  SysUtils, StrUtils, Math, Grammar;

const
  DelphiReservedWords = '.and.array.as.asm.automated.begin.case.class.const.constructor.destructor.dispinterface.div.do.downto.else.end.except.exports.' +
    'file.finalization.finally.for.function.goto.if.implementation.in.inherited.initialization.inline.interface.is.label.library.mod.nil.' +
    'not.object.of.or.out.packed.private.procedure.program.property.protected.public.published.raise.record.repeat.resourcestring.set.shl.shr.' +
    'strict.then.threadvar.to.try.type.unit.until.uses.var.while.with.xor.';
  FPCReservedWords = 'operator.';
  Kinds : array[TTokenKind] of string = ('Undefined', 'Identifier', 'String Constant', 'Char Constant', 'Integer Constant', 'Real Constant', 'Constant Expression',
     'Label Identifier', 'Type Identifier', 'Class Identifier', 'Reserved Word', 'Special Symbol');
  ConditionalSymbols : string = '.llvm.ver2010.mswindows.win32.cpu386.conditionalexpressions.purepascal.';

constructor TScanner.Create(MaxErrors : integer = 10); begin
  FInitTime  := Now;
  FMaxErrors := MaxErrors;
  DecimalSeparator  := '.';
  ThousandSeparator := ',';
  ReservedWords := DelphiReservedWords;
end;

destructor TScanner.Destroy;
var
  Elapsed : TDateTime;
begin
  Elapsed := Now-InitTime;
  if Elapsed = 0 then Elapsed := 3E-9;
  writeln;
  if Errors <> 0 then writeln(Errors, ' error(s).');
  writeln(TotalLines, ' lines, ', IfThen(FormatDateTime('n', Elapsed) = '0', '', FormatDateTime('n ', Elapsed) + 'minutes and '),
    FormatDateTime('s.z ', Elapsed), 'seconds, ', TotalLines/1000.0/(Elapsed*24*60*60):0:1, ' klps.');
  inherited;
  FToken.Free;
  FreeAndNil(Macros);
end;

procedure TScanner.ScanChars(const Chars : array of TSetChar; const Tam : array of integer; Optional : boolean = false);
var
  I, T, Last : integer;
begin
  FToken.Lexeme := '';
  FToken.Kind   := tkUndefined;
  for I := 0 to high(Chars) do begin
    Last := First;
    T    := 1;
    while (Last <= LenLine) and (T <= Tam[I]) and (Line[Last] in Chars[I]) do begin
      inc(Last);
      inc(T);
    end;
    if Last > First then begin
      FToken.Lexeme := FToken.Lexeme + copy(Line, First, Last - First);
      First := Last;
    end
    else
      if Optional then exit;
  end;
end;

procedure TScanner.SetFSourceName(const Value : string); begin
  if FErrors >= FMaxErrors then Abort;
  if FileExists(SourceName) then close(Arq);
  FSourceName := Value;
  FLineNumber := 0;
  FEndSource  := false;
  LenLine     := 0;
  NestedIf    := '';
  if FileExists(SourceName) then begin
    assign(Arq, SourceName);
    writeln(IfThen(Errors = 0, '', ^J), ExtractFileName(SourceName));
    reset(Arq);
    First := 1;
    FToken := TToken.Create;
    FreeAndNil(Macros);
    NextToken;
  end
  else begin
    FEndSource := true;
    Error('Source file ''' + SourceName + ''' not found');
    Abort;
  end;
end;

procedure TScanner.NextChar(C : TSetChar); begin
  if (First < LenLine) and (Line[First + 1] in C) then begin
    FToken.Lexeme := copy(Line, First, 2);
    inc(First, 2);
  end
  else begin
    FToken.Lexeme := Line[First];
    inc(First);
  end;
  FToken.Kind := tkSpecialSymbol;
end;

procedure TScanner.DoIf(Condition : boolean); begin
  if Condition then begin
    NestedIf := NestedIf + 'T';
    FStartComment := '$';
  end
  else begin
    NestedIf := NestedIf + 'F';
    FEndComment := 'ENDIF' + FEndComment;
  end;
end;

procedure TScanner.DoDirective(DollarInc : integer);
var
  I : integer;
  L : string;
begin
  First := DollarInc + 1;
  if Line[First] in ['A'..'Z', '_', 'a'..'z'] then begin
    ScanChars([['A'..'Z', 'a'..'z', '_', '0'..'9']], [255]);
    L := FToken.Lexeme;
    SkipBlank;
    ScanChars([['A'..'Z', 'a'..'z', '_', '0'..'9']], [255]);
    case AnsiIndexText(L, ['DEFINE', 'UNDEF', 'IFDEF', 'IFNDEF', 'IF', 'IFOPT', 'ENDIF', 'IFEND', 'ELSE', 'ELSEIF', 'MODE', 'I', 'INCLUDE']) of
      0 : begin
        if not TokenIn(ConditionalSymbols) then ConditionalSymbols := ConditionalSymbols + LowerCase(FToken.Lexeme) + '.';
        CreateMacro;
      end;
      1 : begin
        I := pos('.' + LowerCase(FToken.Lexeme) + '.', ConditionalSymbols);
        if I <> 0 then delete(ConditionalSymbols, I, length(FToken.Lexeme) + 1);
      end;
      2 : DoIf(TokenIn(ConditionalSymbols));
      3 : DoIf(not TokenIn(ConditionalSymbols));
      4, 9 : if AnsiIndexText(FToken.Lexeme, ['DEFINED', 'DECLARED']) <> -1 then begin
        ScanChars([['(']], [1]);
        ScanChars([['A'..'Z', 'a'..'z', '_', '0'..'9']], [255]);
        DoIf(TokenIn(ConditionalSymbols));
      end;
      5 : DoIf(false);
      6, 7 : if NestedIf <> '' then SetLength(NestedIf, length(NestedIf)-1);
      8 : DoIf(not((NestedIf = '') or (NestedIf[length(NestedIf)] = 'T')));
      10 : ReservedWords := IfThen(pos('FPC', UpperCase(FToken.Lexeme)) = 0 , DelphiReservedWords, DelphiReservedWords + FPCReservedWords);
      11, 12 : ;
    end;
    FindEndComment(FStartComment, FEndComment);
  end
  else begin
    Error('Invalid compiler directive ''' + Line[First] + '''');
    inc(First);
  end;
end;

procedure TScanner.FindEndComment(const StartComment, EndComment : shortstring);
  procedure DoEndIf; begin
    FEndComment := copy(FEndComment, 6, 100);
    if NestedIf <> '' then SetLength(NestedIf, length(NestedIf)-1);
    dec(First, 5);
  end;
var
  P : integer;
begin
  FStartComment := StartComment;
  FEndComment   := EndComment;
  P := PosEx(FStartComment + '$', Line, First);
  if (P <> 0) and ((NestedIf = '') or (NestedIf[length(NestedIf)] = 'T')) then
    DoDirective(P + length(FStartComment))
  else begin
    while (P <> 0) and ((NestedIf <> '') and (NestedIf[length(NestedIf)] = 'F')) do begin
      First := P + length(FStartComment) + 1;
      if Line[First] in ['A'..'Z', '_', 'a'..'z'] then begin
        ScanChars([['A'..'Z', 'a'..'z', '_', '0'..'9']], [255]);
        case AnsiIndexText(FToken.Lexeme, ['IFDEF', 'IFNDEF', 'IFOPT', 'IF', 'ENDIF', 'IFEND', 'ELSE', 'ELSEIF']) of
          0..3 : begin DoIf(false); exit; end;
          4..5 : DoEndIf;
          6, 7 : if (NestedIf = 'F') or (NestedIf[length(NestedIf)-1] = 'T') then DoEndIf;
        end;
      end;
      P := PosEx(FStartComment + '$', Line, First);
    end;
    P := PosEx(FEndComment, UpperCase(Line), First);
    if P <> 0 then begin // End comment in same line
      First := P + length(FEndComment);
      if length(FEndComment) <= 2 then FEndComment := '';
    end
    else
      First := LenLine + 1;
  end;
end;

procedure TScanner.SkipBlank; begin
  while (First <= LenLine) and (Line[First] in [' ', #9]) do inc(First);
end;

function TScanner.TokenIn(const S : string) : boolean; begin
  Result := pos('.' + LowerCase(FToken.Lexeme) + '.', S) <> 0
end;

procedure TScanner.NextString;
var
  Str : string;
begin
  Str := '';
  repeat
    if Line[First] <> '#' then begin
      inc(First);
      repeat
        ScanChars([[#0..#255] - ['''']], [5000]);
        Str := Str + FToken.Lexeme;
        if (First < LenLine) and (Line[First + 1] = '''') then begin
          Str := Str + '''';
          inc(First, 2);
        end;
      until (First >= LenLine) or (Line[First] = '''');
      inc(First);
    end;
    repeat
      ScanChars([['^'], ['@'..'Z']], [1, 1], true);
      case length(FToken.Lexeme) of
        1 : begin
          FToken.Kind := tkSpecialSymbol;
          exit;
        end;
        2 : Str := Str + char(byte(FToken.Lexeme[2]) - ord('@'))
      end;
    until FToken.Lexeme = '';
    repeat
      ScanChars([['#'], ['0'..'9']], [1, 3], true);
      case length(FToken.Lexeme) of
        1 :
          if Line[First] = '$' then begin
            ScanChars([['$'], ['0'..'9', 'A'..'F', 'a'..'f']], [1, 4]);
            Str := Str + char(StrToIntDef(FToken.Lexeme, 0));
          end
          else begin
            FToken.Kind := tkSpecialSymbol;
            exit;
          end;
        2..6 : Str := Str + char(StrToIntDef(copy(FToken.Lexeme, 2, 100), 0))
      end;
    until FToken.Lexeme = '';
  until (First >= length(Line)) or (Line[First] <> '''');
  FToken.Lexeme := Str;
  if length(FToken.Lexeme) = 1 then
    FToken.Kind := tkCharConstant
  else
    FToken.Kind := tkStringConstant;
end;

procedure TScanner.NextToken(Skip : boolean = false);
var
  Str : string;
  FAnt, I : integer;
begin
  while not FEndSource do begin
    while First > LenLine do begin
      readln(Arq, Line);
      LenLine := length(Line);
      if EOF(Arq) and ((LenLine = 0) or (Line = ^Z)) then begin
        if FToken.Lexeme = 'End of Source' then
          FEndSource := true
        else
          FToken.Lexeme := 'End of Source';
        FEndComment := '';
        exit;
      end;
      inc(FLineNumber);
      inc(FTotalLines);
      First := 1;
      if (Macros <> nil) and (LenLine <> 0) and (FEndComment = '') and ((NestedIf = '') or (NestedIf[length(NestedIf)] = 'T')) then
        for I := 0 to Macros.Count - 1 do // Replace macros
          Line := AnsiReplaceStr(Line, Macros.Names[I], Macros.ValueFromIndex[I]);
    end;
    // End comment across many lines
    if FEndComment <> '' then begin
      FindEndComment(FStartComment, FEndComment);
      continue;
    end;
    case Line[First] of
      ' ', #9 : SkipBlank;
      'A'..'Z', 'a'..'z', '_', '&' : begin // Identifiers
        ScanChars([['A'..'Z', 'a'..'z', '_', '&', '0'..'9'], ['A'..'Z', 'a'..'z', '_', '0'..'9']], [1, 254]);
        if (length(FToken.Lexeme) < 2) or not TokenIn(ReservedWords) then
          FToken.Kind := tkIdentifier
        else
          FToken.Kind := tkReservedWord;
        exit;
      end;
      ';', ',', '=', ')', '[', ']', '+', '-', '@' : begin
        FToken.Lexeme := Line[First];
        FToken.Kind   := tkSpecialSymbol;
        inc(First);
        exit;
      end;
      '^' : begin
        Str  := '';
        FAnt := First;
        repeat
          ScanChars([['^'], ['@'..'Z', 'a'..'z', '_', '0'..'9']], [1, 2], true);
          if length(FToken.Lexeme) = 2 then
            Str := Str + char(byte(FToken.Lexeme[2]) - ord('@'));
        until length(FToken.Lexeme) <> 2;
        FToken.Lexeme := Str;
        case length(FToken.Lexeme) of
          0 : begin
            First         := FAnt + 1;
            FToken.Lexeme := Line[First-1];
            FToken.Kind   := tkSpecialSymbol;
          end;
          1 : FToken.Kind := tkCharConstant
        else
          FToken.Kind := tkStringConstant;
        end;
        exit;
      end;
      '''', '#': begin NextString; exit; end; // strings
      '0'..'9' : begin // Numbers
        ScanChars([['0'..'9'], ['.', 'E', 'e']], [28, 1], true);
        Str := FToken.Lexeme;
        case Str[length(Str)] of
          '.' : begin
            ScanChars([['0'..'9'], ['E', 'e'], ['+', '-'], ['0'..'9']], [27, 1, 1, 4], true);
            Str := Str + UpperCase(FToken.Lexeme);
            FToken.Lexeme := '';
            if Str[length(Str)] = 'E' then ScanChars([['0'..'9']], [4]);
          end;
          'E', 'e' : begin
            ScanChars([['+', '-'], ['0'..'9']], [1, 4]);
            Str := Str + FToken.Lexeme;
            FToken.Lexeme := '';
          end;
        end;
        FToken.Lexeme := Str + UpperCase(FToken.Lexeme);
        if FToken.Lexeme[length(FToken.Lexeme)] in ['.', 'E', '+', '-'] then begin
          dec(First);
          SetLength(FToken.Lexeme, length(FToken.Lexeme)-1);
        end;
        if (pos('.', FToken.Lexeme) <> 0) or (pos('E', UpperCase(FToken.Lexeme)) <> 0) then
          FToken.Kind := tkRealConstant
        else
          if length(FToken.Lexeme) > 18 then
            FToken.Kind := tkRealConstant
          else
            FToken.Kind := tkIntegerConstant;
        if FToken.Kind = tkRealConstant then
          FToken.RealValue := StrToFloat(FToken.Lexeme)
        else
          FToken.IntegerValue := StrToInt64(FToken.Lexeme);
        exit;
      end;
      '(' :
        if (LenLine > First) and (Line[First + 1] = '*') then // Comment Style (*
          FindEndComment('(*', '*)')
        else begin
          FToken.Lexeme := '(';
          FToken.Kind   := tkSpecialSymbol;
          inc(First);
          exit
        end;
      '/' :
        if (LenLine > First) and (Line[First + 1] = '/') then // Comment Style //
          First := MAXINT
        else begin
          FToken.Lexeme := '/';
          FToken.Kind   := tkSpecialSymbol;
          inc(First);
          exit
        end;
      '{' : FindEndComment('{', '}');
      '.' : begin NextChar(['.']); exit; end;
      '*' : begin NextChar(['*']); exit; end;
      '>',
      ':' : begin NextChar(['=']); exit; end;
      '<' : begin NextChar(['=', '>']); exit; end;
      '$' : begin // Hexadecimal
        ScanChars([['$'], ['0'..'9', 'A'..'F', 'a'..'f']], [1, 16]);
        FToken.Kind := tkIntegerConstant;
        FToken.IntegerValue := StrToInt64(FToken.Lexeme);
        exit;
      end;
      '%' : begin // Binary
        ScanChars([['%'], ['0', '1']], [1, 32]);
        FToken.Kind := tkIntegerConstant;
        FToken.IntegerValue := 0;
        for I := length(FToken.Lexeme) downto 2 do
          if FToken.Lexeme[I] = '1' then
            inc(FToken.IntegerValue, trunc(Power(2, length(FToken.Lexeme) - I)));
        exit;
      end;
    else
      if not EOF(Arq) and not Skip then Error('Invalid character ''' + Line[First] + ''' ($' + IntToHex(ord(Line[First]), 4) + ')');
      inc(First);
    end;
  end;
end;

procedure TScanner.Error(const Msg : string); begin
  writeln('[Error] ' + ExtractFileName(SourceName) + '('+ IntToStr(LineNumber) + ', ' + IntToStr(ColNumber) + '): ' + Msg);
  inc(FErrors);
  if FErrors >= FMaxErrors then FEndSource := true;
end;

function ReplaceSpecialChars(const S : string) : string;
var
  I : integer;
begin
  Result := '';
  for I := 1 to length(S) do
    if S[I] >= ' ' then
      Result := Result + S[I]
    else
      Result := Result + '#' + IntToStr(byte(S[I]));
end;

procedure TScanner.RecoverFromError(const Expected, Found : string); begin
  if Expected <> '' then Error(Expected + ' expected but ''' + ReplaceSpecialChars(Found) + ''' found');
end;

procedure TScanner.MatchTerminal(KindExpected : TTokenKind); begin
  if KindExpected = FToken.Kind then begin
    LastGoodTop := Top;
    NextToken
  end
  else
    RecoverFromError(Kinds[KindExpected], FToken.Lexeme)
end;

procedure TScanner.MatchToken(const TokenExpected : string); begin
  if TokenExpected = UpperCase(FToken.Lexeme) then begin
    LastGoodTop := Top;
    NextToken
  end
  else
    RecoverFromError('''' + TokenExpected + '''', FToken.Lexeme)
end;

function TScanner.CharToTokenKind(N : char) : TTokenKind; begin
  Result := TTokenKind(byte(N) - byte(pred(Ident)))
end;

function TScanner.TokenKindToChar(T : TTokenKind) : char; begin
  Result := char(byte(T) + byte(pred(Ident)))
end;

function TScanner.GetNonTerminalName(N : char): string; begin
  Result := Kinds[CharToTokenKind(N)]
end;

procedure TScanner.CreateMacro;
var
  Macro : string;
begin
  Macro := FToken.Lexeme;
  SkipBlank;
  ScanChars([[':'], ['=']], [1, 1]);
  if FToken.Lexeme <> '' then begin
    SkipBlank;
    ScanChars([[#0..#255] - ['}']], [50000]);
    if Macros = nil then Macros := TStringList.Create;
    Macros.Add(Macro + '=' + FToken.Lexeme);
  end;
end;

end.