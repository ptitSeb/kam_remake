unit KM_AIArmyEvaluation;
{$I KaM_Remake.inc}
interface
uses
  KM_Defaults, KM_CommonClasses;

type
  TKMGroupEval = record
    HitPoints, Attack, AttackHorse, Defence, DefenceProjectiles: Single;
  end;
  TKMArmyEval = array[TKMGroupType] of TKMGroupEval;
  TKMGameEval = array[0 .. MAX_HANDS - 1] of TKMArmyEval;

  TKMGroupStrengthArray = array[TKMGroupType] of Single;

  //This class evaluate self army relatively enemy armies
  TKMArmyEvaluation = class
  private
    fEvals: TKMGameEval; //Results of evaluation

    function CalculateStrength(aEval: TKMArmyEval): TKMGroupStrengthArray;
    function GetUnitEvaluation(aUT: TKMUnitType; aConsiderHitChance: Boolean = False): TKMGroupEval;
    function GetEvaluation(aPlayer: TKMHandIndex): TKMArmyEval;
    function GetAllianceStrength(aPlayer: TKMHandIndex; aAlliance: TKMAllianceType): TKMArmyEval;
    procedure EvaluatePower(aPlayer: TKMHandIndex; aConsiderHitChance: Boolean = False);
  public
    constructor Create();
    destructor Destroy; override;
    procedure Save(SaveStream: TKMemoryStream);
    procedure Load(LoadStream: TKMemoryStream);

    property UnitEvaluation[aUT: TKMUnitType; aConsiderHitChance: Boolean]: TKMGroupEval read GetUnitEvaluation;
    property Evaluation[aPlayer: TKMHandIndex]: TKMArmyEval read GetEvaluation;
    property AllianceEvaluation[aPlayer: TKMHandIndex; aAlliance: TKMAllianceType]: TKMArmyEval read GetAllianceStrength;

    function CompareStrength(aPlayer, aOponent: TKMHandIndex): Single;
    function CompareAllianceStrength(aPlayer, aOponent: TKMHandIndex): Single;
    procedure UpdateState(aTick: Cardinal);
  end;

const
  HIT_CHANCE_MODIFIER = 0.5;

implementation
uses
  Math,
  KM_Hand, KM_HandsCollection, KM_HandStats,
  KM_Resource, KM_ResUnits;


{ TKMArmyEvaluation }
constructor TKMArmyEvaluation.Create();
begin
  inherited Create;
  FillChar(fEvals, SizeOf(fEvals), #0);
end;


destructor TKMArmyEvaluation.Destroy;
begin
  inherited;
end;


procedure TKMArmyEvaluation.Save(SaveStream: TKMemoryStream);
begin
  SaveStream.WriteA('ArmyEvaluation');
  SaveStream.Write(fEvals, SizeOf(fEvals));
end;


procedure TKMArmyEvaluation.Load(LoadStream: TKMemoryStream);
begin
  LoadStream.ReadAssert('ArmyEvaluation');
  LoadStream.Read(fEvals, SizeOf(fEvals));
end;


function TKMArmyEvaluation.GetUnitEvaluation(aUT: TKMUnitType; aConsiderHitChance: Boolean = False): TKMGroupEval;
var
  US: TKMUnitSpec;
begin
  // Fill array with reference values
  US := gRes.Units[aUT];
  with Result do
  begin
    Hitpoints :=          US.Hitpoints;
    Attack :=             US.Attack;
    AttackHorse :=        US.AttackHorse;
    Defence :=            US.Defence;
    DefenceProjectiles := US.GetDefenceVsProjectiles(False);
    if aConsiderHitChance AND (UnitGroups[aUT] = gt_Ranged) then
      Attack := Attack * HIT_CHANCE_MODIFIER;
  end;
end;


function TKMArmyEvaluation.GetEvaluation(aPlayer: TKMHandIndex): TKMArmyEval;
begin
  Move(fEvals[aPlayer], Result, SizeOf(fEvals[aPlayer]));
end;


function TKMArmyEvaluation.CalculateStrength(aEval: TKMArmyEval): TKMGroupStrengthArray;
  var
    GT: TKMGroupType;
  begin
    for GT := Low(TKMGroupType) to High(TKMGroupType) do
      with aEval[GT] do
        Result[GT] := Attack * Hitpoints * Defence;
        //Result[GT] := Attack * Max(1, AttackHorse) * Hitpoints * Defence;
  end;


function TKMArmyEvaluation.CompareStrength(aPlayer, aOponent: TKMHandIndex): Single;
var
  Sum, Diff: Single;
  GT: TKMGroupType;
  PlayerArmy, EnemyArmy: TKMGroupStrengthArray;
begin
  PlayerArmy := CalculateStrength( Evaluation[aPlayer] );
  EnemyArmy := CalculateStrength( Evaluation[aOponent] );
  Sum := 0;
  Diff := 0;
  for GT := Low(TKMGroupType) to High(TKMGroupType) do
  begin
    Sum := Sum + PlayerArmy[GT] + EnemyArmy[GT];
    Diff := Diff + PlayerArmy[GT] - EnemyArmy[GT];
  end;
  Result := Diff / Max(1,Sum); // => number in <-1,1> ... positive = we have advantage and vice versa
end;


function TKMArmyEvaluation.GetAllianceStrength(aPlayer: TKMHandIndex; aAlliance: TKMAllianceType): TKMArmyEval;
var
  PL: Integer;
  GT: TKMGroupType;
begin
  FillChar(Result, SizeOf(Result), #0);
  for PL := 0 to gHands.Count - 1 do
    if gHands[PL].Enabled AND (gHands[aPlayer].Alliances[PL] = aAlliance) then
      for GT := Low(TKMGroupType) to High(TKMGroupType) do
        with Result[GT] do
        begin
          Hitpoints          := Hitpoints          + fEvals[PL,GT].Hitpoints;
          Attack             := Attack             + fEvals[PL,GT].Attack;
          AttackHorse        := AttackHorse        + fEvals[PL,GT].AttackHorse;
          Defence            := Defence            + fEvals[PL,GT].Defence;
          DefenceProjectiles := DefenceProjectiles + fEvals[PL,GT].DefenceProjectiles;
        end;
end;


// Approximate way how to compute strength of 2 alliances
function TKMArmyEvaluation.CompareAllianceStrength(aPlayer, aOponent: TKMHandIndex): Single;
var
  Sum, Diff: Single;
  GT: TKMGroupType;
  AllyEval, EnemyEval: TKMArmyEval;
  AllyArmy, EnemyArmy: TKMGroupStrengthArray;
begin
  AllyEval := GetAllianceStrength(aPlayer, at_Ally);
  EnemyEval := GetAllianceStrength(aOponent, at_Ally);
  AllyArmy := CalculateStrength(AllyEval);
  EnemyArmy := CalculateStrength(EnemyEval);
  Sum := 0;
  Diff := 0;
  for GT := Low(TKMGroupType) to High(TKMGroupType) do
  begin
    Sum := Sum + AllyArmy[GT] + EnemyArmy[GT];
    Diff := Diff + AllyArmy[GT] - EnemyArmy[GT];
  end;
  Result := Diff / Max(1,Sum); // => number in <-1,1> ... positive = we have advantage and vice versa
end;


// Actualize power of specific player
//
// Equation of combat:
//
//   Close combat
//                    Attack (+ AttackHorse) (+ DirModifier)   -> DirModifier is not considered in ArmyEvaluation
//     Probability = ---------------------------------------
//                                 Defence
//
//   Ranged units
//     HitProbability = 1 - Distance;  Distance in <0,1>       -> Hit probability is considered as a decreasing of attack by HIT_CHANCE_MODIFIER
//                         Attack
//     Probability = --------------------
//                    DefenceProjectiles
//
// Probability > random number => decrease hitpoint; 0 hitpoints = unit is dead
procedure TKMArmyEvaluation.EvaluatePower(aPlayer: TKMHandIndex; aConsiderHitChance: Boolean = False);
var
  Stats: TKMHandStats;
  Qty: Integer;
  US: TKMUnitSpec;
  UT: TKMUnitType;
  GT: TKMGroupType;
begin
  Stats := gHands[aPlayer].Stats;

  // Clear array
  FillChar(fEvals[aPlayer], SizeOf(fEvals[aPlayer]), #0);

  // Fill array with reference values
  for UT := WARRIOR_MIN to WARRIOR_MAX do
  begin
    Qty := Stats.GetUnitQty(UT);
    US := gRes.Units[UT];
    GT := UnitGroups[UT];
    with fEvals[aPlayer,GT] do
    begin
      Hitpoints := Hitpoints + Qty * US.HitPoints;
      Attack := Attack + Qty * US.Attack;
      AttackHorse := AttackHorse + Qty * US.AttackHorse;
      Defence := Defence + Qty * US.Defence;
      DefenceProjectiles := DefenceProjectiles + Qty * US.GetDefenceVsProjectiles(False); // True = IsBolt -> calculation without bolts
    end;
  end;
  if aConsiderHitChance then
    with fEvals[aPlayer,gt_Ranged] do
      Attack := Attack * HIT_CHANCE_MODIFIER;
end;


procedure TKMArmyEvaluation.UpdateState(aTick: Cardinal);
const
  PERF_SUM = MAX_HANDS * 10;
var
  PL: TKMHandIndex;
begin
  PL := aTick mod PERF_SUM;
  if (PL < gHands.Count) AND gHands[PL].Enabled then
    EvaluatePower(PL, True);
end;


end.
