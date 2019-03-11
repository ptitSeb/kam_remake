unit KM_NavMesh;
{$I KaM_Remake.inc}
interface
uses
  KM_PolySimplify,
  KM_CommonClasses, KM_CommonTypes, KM_Defaults, KM_Points, Contnrs,
  KM_NavMeshDefences,
  KromUtils, KM_CommonUtils,
  KM_NavMeshFloodPositioning, KM_NavMeshPathFinding;// TimeGet


type

  TKMNavMeshByteArray = array[-1..257,-1..257] of Byte;
  TKMNavMeshWordArray = array[-1..257,-1..257] of Word;

  // Borders
  TKMBord = record
    Node, Prev, Next, NextY: Word;
  end;
  TKMBordInfo = record
    Count: Word;
    Borders: array[0..6000] of TKMBord;
  end;

  // PolyLines
  PPolyLine = ^TKMPolyLine;
  TKMPolyLine = record
    Node,Polygon: Word;
    Next: PPolyLine;
  end;
  PPolyLines = ^TKMPolyLines;
  TKMPolyLines = record
  	LeftEdge, RightEdge, FutureLeftEdge, FutureRightEdge: Word;
    FirstLine, LastLine: PPolyLine;
  end;


  TDebugLines = record // Only for debug
    Count: Word;
    Lines: array[0..15000] of record
      P1,P2: TKMPoint;
    end;
  end;

  TPolygon = record
      CenterPoint: TKMPoint;
      NearbyCount: Byte; //could be 0 .. 3
      Poly2PointStart, Poly2PointCnt: Word; // Indexes of fPolygon2PointArr (points which are part of this polygon)
      Indices: array [0..2] of Word; //Neighbour nodes
      Nearby: array [0..2] of Word; //Neighbour polygons
      NearbyPoints: array [0..2] of TKMPoint; // Center points
    end;

  TPolygonArray = array of TPolygon;

  //NavMesh is used to acess the map on a higher level than tiles
  //terrain is represented as a mesh interconnected polygons
  TKMNavMesh = class
  private
    fMapX, fMapY: Word; // Limits of arrays
    //Keep a copy of these temp arrays for debug rendering
    fInnerPointStartIdx, fInnerPointEndIdx: Word;
    fBordByY, fIdxArr: array[0..256] of Word;
    fBord: TKMBordInfo;
    fDL, fDL2: TDebugLines;

    //Working data
    fNodeCount: Integer;
    fPolyCount: Integer;
    fNodes: TKMPointArray;            // Nodes
    fPolygons: TPolygonArray;         // Polygons
    fPoint2PolygonArr: TKMWordArray;  // KMPoint -> Polygon index
    //fPolygon2PointArr: TKMPointArray; // Polygon index -> KMPoint

    fDefences: TForwardFF; //Defences class
    fPathfinding: TNavMeshPathFinding; // NavMesh Pathfinding
    fPositioning: TNavMeshFloodPositioning; // NavMesh Positioning

    //Building the navmesh from terrain
    procedure ExtractPolygons();
    procedure PolygonTriangulation();
    procedure PrettyPoly();
    procedure FindClosestPolygon();
    procedure TieUpTilesWithPolygons();
    procedure TieUpPolygonsWithTiles();

    function GetPolygonFromPoint(const aY,aX: Integer): Word;
    function GetPolygonFromKMPoint(const aPoint: TKMPoint): Word;

  public
    constructor Create();
    destructor Destroy(); override;
    procedure Save(SaveStream: TKMemoryStream);
    procedure Load(LoadStream: TKMemoryStream);

    property Point2Polygon[const aY,aX: Integer]: Word read GetPolygonFromPoint;
    property KMPoint2Polygon[const aPoint: TKMPoint]: Word read GetPolygonFromKMPoint;
    //property Polygon2Point: TKMPointArray read fPolygon2PointArr;
    property Polygons: TPolygonArray read fPolygons;
    property Nodes: TKMPointArray read fNodes;
    property Defences: TForwardFF read fDefences write fDefences;
    property Pathfinding: TNavMeshPathFinding read fPathfinding write fPathfinding;
    property Positioning: TNavMeshFloodPositioning read fPositioning write fPositioning;

    procedure AfterMissionInit();

    procedure UpdateState(aTick: Cardinal);
    procedure Paint(const aRect: TKMRect);
  end;


implementation
uses
  SysUtils, Math, Delaunay,
  KM_Terrain, KM_HandsCollection, KM_RenderAux, KM_Outline,
  Dialogs;


{ TKMNavMesh }
constructor TKMNavMesh.Create();
begin
  inherited Create;

  fDefences := TForwardFF.Create(True);
  fPathfinding := TNavMeshPathFinding.Create();
  fPositioning := TNavMeshFloodPositioning.Create();
end;


destructor TKMNavMesh.Destroy();
begin
  fDefences.Free;
  fPathfinding.Free;
  fPositioning.Free;
  inherited;
end;


procedure TKMNavMesh.Save(SaveStream: TKMemoryStream);
var
  I: Integer;
begin
  SaveStream.WriteA('NavMesh');
  SaveStream.Write(fMapX);
  SaveStream.Write(fMapY);

  SaveStream.Write(fNodeCount);
  SaveStream.Write(fNodes[0], SizeOf(fNodes[0]) * fNodeCount);

  SaveStream.Write(fPolyCount);
  SaveStream.Write(fPolygons[0], SizeOf(fPolygons[0]) * fPolyCount);
  // Maybe this code will save work in future
  //for I := 0 to fPolyCount - 1 do
  //begin
  //  SaveStream.Write(fPolygons[I].CenterPoint);
  //  SaveStream.Write(fPolygons[I].Indices, SizeOf(fPolygons[I].Indices));
  //  SaveStream.Write(fPolygons[I].NearbyCount);
  //  SaveStream.Write(fPolygons[I].Poly2PointStart);
  //  SaveStream.Write(fPolygons[I].Poly2PointCnt);
  //  SaveStream.Write(fPolygons[I].Nearby, SizeOf(fPolygons[I].Nearby));
  //  SaveStream.Write(fPolygons[I].NearbyPoints, SizeOf(fPolygons[I].NearbyPoints));
  //end;

  I := Length(fPoint2PolygonArr);
  SaveStream.Write( I );
  SaveStream.Write(fPoint2PolygonArr[0], SizeOf(fPoint2PolygonArr[0]) * I );

  //I := Length(fPolygon2PointArr);
  //SaveStream.Write( I );
  //SaveStream.Write(fPolygon2PointArr[0], SizeOf(fPolygon2PointArr[0]) * I );

  // The following does not requires save
  // fDefences
  // fPathfinding
  // fPositioning
end;


procedure TKMNavMesh.Load(LoadStream: TKMemoryStream);
var
  I: Integer;
begin
  LoadStream.ReadAssert('NavMesh');
  LoadStream.Read(fMapX);
  LoadStream.Read(fMapY);

  LoadStream.Read(fNodeCount);
  SetLength(fNodes, fNodeCount);
  LoadStream.Read(fNodes[0], SizeOf(fNodes[0]) * fNodeCount);

  LoadStream.Read(fPolyCount);
  SetLength(fPolygons, fPolyCount);
  LoadStream.Read(fPolygons[0], SizeOf(fPolygons[0]) * fPolyCount);
  //for I := 0 to fPolyCount - 1 do
  //begin
  //  LoadStream.Read(fPolygons[I].CenterPoint);
  //  LoadStream.Read(fPolygons[I].Indices, SizeOf(fPolygons[I].Indices));
  //  LoadStream.Read(fPolygons[I].NearbyCount);
  //  LoadStream.Read(fPolygons[I].Poly2PointStart);
  //  LoadStream.Read(fPolygons[I].Poly2PointCnt);
  //  LoadStream.Read(fPolygons[I].Nearby, SizeOf(fPolygons[I].Nearby));
  //  LoadStream.Read(fPolygons[I].NearbyPoints, SizeOf(fPolygons[I].NearbyPoints));
  //end;

  LoadStream.Read(I);
  SetLength(fPoint2PolygonArr,I);
  LoadStream.Read(fPoint2PolygonArr[0], SizeOf(fPoint2PolygonArr[0]) * I );

  //LoadStream.Read(I);
  //SetLength(fPolygon2PointArr,I);
  //LoadStream.Read(fPolygon2PointArr[0], SizeOf(fPolygon2PointArr[0]) * I );
end;


procedure TKMNavMesh.AfterMissionInit();
var
  Time: Cardinal;
begin
  fMapX := gTerrain.MapX;
  fMapY := gTerrain.MapY;

  Time := TimeGet();
  // Get border lines which represents polygons and inner points if border points are too far away
  ExtractPolygons();
  // Triangulate polygons and inner points, assemble connection is part of this process
  PolygonTriangulation();
  // Improve shape of polygons (we dont need perfect polygons but it is nice to polish it in 1-2 [ms])
  PrettyPoly();
  //Mapp all map tiles to its polygons and vice versa
  TieUpTilesWithPolygons();
  TieUpPolygonsWithTiles();

  Time := TimeGet() - Time;
end;


procedure TKMNavMesh.UpdateState(aTick: Cardinal);
begin

end;


procedure TKMNavMesh.ExtractPolygons();
const
  UNVISITED_OBSTACLE = 255;
  VISITED_OBSTACLE = UNVISITED_OBSTACLE - 1;
  BORDER_STEP = 4;
  STEP = 5;
var
  EndfBordByY: array[0..256] of Word;
  N: TKMNavMeshWordArray; // 2D array with fixed size is fast as 1D array
  W: TKMNavMeshByteArray;


  procedure AddBorder(aPoint: TKMPoint);
  begin
    N[aPoint.Y,aPoint.X] := fNodeCount;
    fNodes[fNodeCount] := aPoint;
    Inc(fNodeCount);
  end;

  procedure AddBorderEdge(aPoint: TKMPoint);
  begin
    // Add verticle if it is required (UNVISITED_OBSTACLE or VISITED_OBSTACLE)
    if (N[aPoint.Y,aPoint.X] = 0) then
      AddBorder(aPoint);
    // Add border connection
    with fBord.Borders[fBord.Count] do
    begin
      Node := fNodeCount - 1;
      //Node := N[aPoint.Y,aPoint.X];
      Prev := fBord.Count - 1; // Borders does not exist yet but they will exist in future or will be fixed in next code
      Next := fBord.Count + 1;
      NextY := 0; // 0. index is reserved (= not used)
    end;
    Inc(fBord.Count);
  end;

  //procedure ScanObstacle(aRightHanded: Boolean; aStartPoint, aEndPoint, aInitDir: TKMPoint);
  procedure ScanObstacle(aStartPoint, aEndPoint, aInitDir: TKMPoint);
  const
    MAX_TOLERANCE = 0.99; // Maximal allowed distance between point and line
    MAX_DISTANCE = 6; // Maximal count of edge points without verticle
    //CorrArr: array[-2..2] of TKMPoint = ( (X:-1;Y:-1), (X:-1;Y:0), (X:0;Y:0), (X:0;Y:-1), (X:0;Y:0) );
    CorrArr: array[-2..2] of TKMPoint = ( (X:-1;Y:0), (X:0;Y:0), (X:0;Y:0), (X:-1;Y:-1), (X:0;Y:-1) );
  var
    Cnt: Integer;
    Points, Directions, FixDir: array[0..MAX_DISTANCE] of TKMPoint;
    procedure AddBorderPoint(aBorder,aDirection: TKMPoint);
    begin
      FixDir[Cnt] := KMPointAdd( aBorder, CorrArr[aDirection.X+aDirection.Y*2] );
      if (N[FixDir[Cnt].Y,FixDir[Cnt].X] = 0) then
      begin
        Points[Cnt] := aBorder;
        Directions[Cnt] := aDirection;
        Cnt := Cnt + 1;
      end;
    end;
  var
    InnerTile: Boolean;
    I,X,Y,{Dir,} Overflow, Distance: Integer;
    InvDenominator, a,b,c: Single;
    v, TestP: TKMPoint;
  begin
    X := aStartPoint.X;
    Y := aStartPoint.Y;
    v := aInitDir; // Init vector
    //Dir := ifthen(aRightHanded, -1, 1); // Determine direction of rotation
    Cnt := 0;
    Distance := MAX_DISTANCE; // Make sure that first point will be added
    Overflow := 0;
    repeat
      Overflow := Overflow + 1;
      Distance := Distance + 1;
      InnerTile := False;
      // Find next CanBeVisited tile and rotate vector
      if (W[ Y-v.X{*Dir}, X+v.Y{*Dir} ] > 0) then // Left {Right}
      begin
        InnerTile := True;
        Distance := Distance - 1; // Ignore inner edges
        v := KMPoint(+v.Y,-v.X);
      end
      else if (W[ Y+v.Y, X+v.X ] > 0) then // Forward
      begin
        //v := KMPoint(+v.X,+v.Y);
      end
      else if (W[ Y+v.X{*Dir}, X-v.Y{*Dir}  ] > 0) then // Right {Left}
      begin
        v := KMPoint(-v.Y,+v.X);
      end
      else if (W[ Y-v.Y, X-v.X ] > 0) then // Backward
      begin
        Distance := MAX_DISTANCE;
        v := KMPoint(-v.X,-v.Y);
      end
      else
        break;
      // Add point which is not inner tiles (does not have walkable tile in 4 surrounding tiles)
      if not InnerTile then
        AddBorderPoint(KMPoint(X,Y), v);
      // Find maximal distance internal points and line which is given by border points
      if (Cnt > 2) then
      begin
        a := - FixDir[0].Y + FixDir[Cnt-1].Y;
        b := + FixDir[0].X - FixDir[Cnt-1].X;
        c := - a * FixDir[0].X - b * FixDir[0].Y;
        InvDenominator := 1 / (a*a + b*b);
        for I := Cnt - 2 downto 1 do // Another optimalization
          if (  ( sqr(a*FixDir[I].X + b*FixDir[I].Y + c) * InvDenominator ) > MAX_TOLERANCE  ) then
          begin
            X := Points[I].X;
            Y := Points[I].Y;
            v := Directions[I];
            Distance := MAX_DISTANCE;
            break;
          end;
      end;
      // Add point in case that distance is greater than threshold
      if (Distance >= MAX_DISTANCE) then
      begin
        TestP := KMPointAdd( KMPoint(X,Y), CorrArr[v.X+v.Y*2] );
        if (N[TestP.Y,TestP.X] = 0) then
        begin
          Distance := 0;
          Cnt := 0;
          AddBorderPoint(KMPoint(X,Y), v);
          AddBorderEdge( TestP );
        end;
      end;
      // Mark visited obstacle and move into next point
      if (W[Y,X] = UNVISITED_OBSTACLE) then
        W[Y,X] := VISITED_OBSTACLE;
      X := X + v.X;
      Y := Y + v.Y;
    until ( KMSamePoint(KMPoint(X,Y),aEndPoint) AND
            //(W[ Y-aInitDir.X, X+aInitDir.Y ] <> UNVISITED_OBSTACLE) AND
            (W[ Y-aInitDir.Y, X-aInitDir.X ] <> UNVISITED_OBSTACLE) )
          OR (Overflow > 65536);
  end;

  // Mark edges - use relative coordinate system: visit surounding tiles and rotate coordinate system
  procedure MarkEdges();
    procedure SortByY(aStartIdx, aEndIdx, aIncrement: Integer);
    var
      I, Y: Integer;
    begin
      I := aStartIdx;
      while (I <> aEndIdx) do
      begin
        Y := fNodes[ fBord.Borders[I].Node ].Y;
        if (fBordByY[Y] = 0) then // First element
          fBordByY[Y] := I
        else // There are already some borders
          fBord.Borders[ EndfBordByY[Y] ].NextY := I;
        EndfBordByY[Y] := I;
        I := I + aIncrement;
      end;
    end;
    procedure SortByY2(aStartCnt, aCnt: Word);
    var
      I, K,PrevK, Y,X: Word;
    begin
      for I := aStartCnt to aCnt - 1 do
      begin
        Y := fNodes[ fBord.Borders[I].Node ].Y;
        X := fNodes[ fBord.Borders[I].Node ].X;
        PrevK := 0;
        K := fBordByY[Y];
        while (K > 0) AND (X > fNodes[ fBord.Borders[K].Node ].X) do
        begin // Insertion sort - in real 10-15 points; in borders max 50 => no need for quick sort
          PrevK := K;
          K := fBord.Borders[K].NextY;
        end;
        if (PrevK = 0) then
          fBordByY[Y] := I
        else
          fBord.Borders[PrevK].NextY := I;
        fBord.Borders[I].NextY := K;
      end;
    end;
  var
    Walkable: Boolean;
    X,Y,Cnt: Integer;
  begin
    fNodeCount := 1;
    fBord.Count := 1;
    Walkable := False;
    for Y := 1 to fMapY - 1 do
    for X := 1 to fMapX do // -1 cannot be here
    begin
      if Walkable AND (W[Y,X] = UNVISITED_OBSTACLE) then
      begin
        Cnt := fBord.Count;
        ScanObstacle(KMPoint(X,Y), KMPoint(X,Y), KMPoint(0,-1));
        if (fBord.Count - Cnt > 2) then // Actualize border values -> close polygon
        begin
          fBord.Borders[Cnt].Prev := fBord.Count - 1;
          fBord.Borders[fBord.Count - 1].Next := Cnt;
          // Sort by Y (=> QuickSort is not required! + order is important)
          //if (W[Y-1,X] = 0) then // Clockwise direction
          //  SortByY(fBord.Count - 1, Cnt - 1, -1)
          //else
          //  SortByY(Cnt, fBord.Count, 1);
          SortByY2(Cnt, fBord.Count);
        end
        else
          fBord.Count := Cnt; // Remove borders / ignore them
      end;
      Walkable := (W[Y,X] = 0);
    end;
  end;

  // Faster method for adding inner points
  procedure AddNodesByFor();
  const
    STEP = 6;
    SQR_MAX_DIST = (STEP - 2) * (STEP - 2);
  var
    Check: Boolean;
    I,Idx,X,Y: Integer;
  begin
    fInnerPointStartIdx := fNodeCount;

    Y := STEP;
    while (Y < fMapY - 1) do
    begin
      X := STEP;
      while (X < fMapX - 1) do
      begin
        if (W[Y,X] = 0) then
        begin
          Check := True;
          for I := Max(0, Y-STEP) to Min(fMapY, Y+STEP+1) do
          begin
            Idx := fBordByY[I];
            while (Idx <> 0) AND Check do
            begin
              Check := KMDistanceSqr(fNodes[ fBord.Borders[Idx].Node ], KMPoint(X,Y)) > SQR_MAX_DIST;
              Idx := fBord.Borders[Idx].NextY;
            end;
            if not Check then
              break;
          end;
          if Check then
            AddBorder( KMPoint(X,Y) );
        end;
        X := X + STEP;
      end;
      Y := Y + STEP;
    end;

    fInnerPointEndIdx := fNodeCount;

    FillChar(fIdxArr, SizeOf(fIdxArr), #0);
    Y := 0;
    I := fInnerPointStartIdx;
    while (I < fInnerPointEndIdx) do
      if (fNodes[I].Y > Y) then
      begin
        fIdxArr[Y] := I;
        Y := Y + 1;
      end
      else
        I := I + 1;
    for Y := Y to High(fIdxArr) do
      fIdxArr[Y] := fInnerPointEndIdx;
  end;


  // More precise method for adding inner points (slowest realization)
  procedure AddNodesFF();
  type
    // Distance + point record for adding new points with flood fill algorithm
    TPointDistRecord = record
      D: Word;
      P: TKMPoint;
    end;
  PDRPointer = ^TPointDistRecord;
  var
    VisitIdx: Byte;
    Queue: TQueue;
    V,E: TKMNavMeshByteArray;

    procedure AddToQueue(aDist: Word; aX,aY: Integer);
    var
      PP: PDRPointer;
    begin
      V[aY,aX] := VisitIdx;
      New(PP);
      PP^.D := aDist;
      PP^.P := KMPoint(aX,aY);
      Queue.Push(PP);
    end;

    procedure FillArea(aStep: Word; aInitPoint: TKMPoint);
    var
      MaxDistance: Word;
      X,Y,MaxX,MaxY: Integer;
      PP: PDRPointer;
    begin
      MaxX := fMapX;
      MaxY := fMapY;
      if (VisitIdx >= 255) then
      begin
        FillChar(V, SizeOf(V), #0);
        VisitIdx := 0;
      end;
      VisitIdx := VisitIdx + 1;
      AddToQueue(aStep, aInitPoint.X, aInitPoint.Y);
      while (Queue.Count > 0) do
      begin
        PP := Queue.Pop;
        MaxDistance := PP^.D;
        X := PP^.P.X;
        Y := PP^.P.Y;
        if (MaxDistance > 0) AND (MaxDistance > E[Y,X]) AND (W[Y,X] < UNVISITED_OBSTACLE) then
        begin
          MaxDistance := MaxDistance - 1;
          E[Y,X] := MaxDistance;
          if (Y < MaxY) AND (V[Y+1,X] < VisitIdx) then AddToQueue(MaxDistance, X,Y+1);
          if (Y > 0)    AND (V[Y-1,X] < VisitIdx) then AddToQueue(MaxDistance, X,Y-1);
          if (X < MaxX) AND (V[Y,X+1] < VisitIdx) then AddToQueue(MaxDistance, X+1,Y);
          if (X > 0)    AND (V[Y,X-1] < VisitIdx) then AddToQueue(MaxDistance, X-1,Y);
        end;
        Dispose(PP);
      end;
    end;
  var
    I,X,Y: Integer;
  begin
    FillChar(E, SizeOf(E), #0);
    fInnerPointStartIdx := fNodeCount;
    Queue := TQueue.Create();
    try
      VisitIdx := 255;
      for I := 1 to fBord.Count - 1 do
        FillArea( BORDER_STEP, fNodes[ fBord.Borders[I].Node ] );

      for Y := 1 to fMapY - 1 do
      for X := 1 to fMapX - 1 do
        if (E[Y,X] = 0) AND (W[Y,X] < UNVISITED_OBSTACLE) then
        begin
          AddBorder( KMPoint(X,Y) );
          FillArea( STEP, KMPoint(X,Y) );
        end;
    finally
      Queue.Free();
    end;
    fInnerPointEndIdx := fNodeCount;

    FillChar(fIdxArr, SizeOf(fIdxArr), #0);
    Y := 0;
    I := fInnerPointStartIdx;
    while (I < fInnerPointEndIdx) do
      if (fNodes[I].Y > Y) then
      begin
        fIdxArr[Y] := I;
        Y := Y + 1;
      end
      else
        I := I + 1;
    for Y := Y to High(fIdxArr) do
      fIdxArr[Y] := fInnerPointEndIdx;
  end;


  // More precise method for adding inner points
  // (faster realization, density of border points must be higher to secure that it will work)
  procedure AddNodesForFF();
  var
    E: TKMNavMeshByteArray;
    procedure FillArea(aStep: Word; aInitPoint: TKMPoint);
    var
      X,Y: Integer;
    begin
      for Y := Max(1, aInitPoint.Y - aStep) to Min(fMapY - 1, aInitPoint.Y + aStep) do
      for X := Max(1, aInitPoint.X - aStep) to Min(fMapX - 1, aInitPoint.X + aStep) do
        E[Y,X] := 1;//Max(  E[Y,X], Min( abs(aInitPoint.Y - Y), abs(aInitPoint.X - X) )  );
    end;
  var
    I,X,Y: Integer;
  begin
    FillChar(E, SizeOf(E), #0);
    fInnerPointStartIdx := fNodeCount;
    for I := 1 to fBord.Count - 1 do
      FillArea( BORDER_STEP+1, fNodes[ fBord.Borders[I].Node ] );

    for Y := 1 to fMapY - 1 do
    for X := 1 to fMapX - 1 do
      if (E[Y,X] = 0) AND (W[Y,X] < VISITED_OBSTACLE) then
      begin
        AddBorder( KMPoint(X,Y) );
        FillArea( STEP+1, KMPoint(X,Y) );
      end;
    fInnerPointEndIdx := fNodeCount;

    FillChar(fIdxArr, SizeOf(fIdxArr), #0);
    Y := 0;
    I := fInnerPointStartIdx;
    while (I < fInnerPointEndIdx) do
      if (fNodes[I].Y > Y) then
      begin
        fIdxArr[Y] := I;
        Y := Y + 1;
      end
      else
        I := I + 1;
    for Y := Y to High(fIdxArr) do
      fIdxArr[Y] := fInnerPointEndIdx;
  end;

var
  X,Y: Integer;
begin
  // Clear array
  fNodeCount := 1;
  fPolyCount := 1;
  SetLength(fNodes, 5000);
  SetLength(fPolygons, 5000);
  FillChar(fNodes[0], SizeOf(fNodes[0]) * Length(fNodes), #0);
  FillChar(fPolygons[0], SizeOf(fPolygons[0]) * Length(fPolygons), #0);
  // Fill borders
  FillChar(W, SizeOf(W), #0);
  FillChar(N, SizeOf(N), #0);
  X := fMapX;
  for Y := 0 to fMapY do
  begin
    W[Y,0] := UNVISITED_OBSTACLE;
    W[Y,X] := UNVISITED_OBSTACLE;
  end;
  Y := fMapY;
  for X := 0 to fMapX do
  begin
    W[0,X] := UNVISITED_OBSTACLE;
    W[Y,X] := UNVISITED_OBSTACLE;
  end;
  // Fill map
  for Y := 1 to fMapY - 1 do
  for X := 1 to fMapX - 1 do
    if not (tpOwn in gTerrain.Land[Y,X].Passability) then
      W[Y,X] := UNVISITED_OBSTACLE;
  // Find edges of polygons
  FillChar(fBordByY, SizeOf(fBordByY), #0);
  FillChar(EndfBordByY, SizeOf(EndfBordByY), #0);
  FillChar(fIdxArr, SizeOf(fIdxArr), #0);
  MarkEdges();
  // Add inner points
  fInnerPointStartIdx := 0;
  fInnerPointEndIdx := 0;
  //AddNodesByFor();
  //AddNodesFF();
  AddNodesForFF();
end;


procedure TKMNavMesh.PolygonTriangulation();
var
  LineArrayCnt: Word;
  LineArray: array of PPolyLines;

  procedure ConfirmLine(aIdx1, aIdx2: Word);
  begin
    with fDL.Lines[fDL.Count] do
    begin
      p1 := fNodes[  fBord.Borders[ aIdx1 ].Node  ];
      p2 := fNodes[  fBord.Borders[ aIdx2 ].Node  ];
    end;
    Inc(fDL.Count);
  end;
  procedure AddLine(aP1,aP2: TKMPoint);
  begin
    with fDL.Lines[fDL.Count] do
    begin
      p1 := aP1;
      p2 := aP2;
    end;
    Inc(fDL.Count);
  end;
  procedure ConfirmLine2(aIdx1, aIdx2: Word);
  begin
    with fDL2.Lines[fDL2.Count] do
    begin
      p1 := fNodes[  fBord.Borders[ aIdx1 ].Node  ];
      p2 := fNodes[  fBord.Borders[ aIdx2 ].Node  ];
    end;
    Inc(fDL2.Count);
  end;
  procedure AddLine2(aP1,aP2: TKMPoint);
  begin
    with fDL2.Lines[fDL2.Count] do
    begin
      p1 := aP1;
      p2 := aP2;
    end;
    Inc(fDL2.Count);
  end;

  procedure ConnectPolygons(aNewPoly1, aPossiblePoly2: Word);
  begin
    if (aPossiblePoly2 = 0) then
      Exit;
    with fPolygons[aNewPoly1] do
      if (NearbyCount < 3) then
      begin
        Nearby[NearbyCount] := aPossiblePoly2;
        Inc(NearbyCount);
      end;
    with fPolygons[aPossiblePoly2] do
      if (NearbyCount < 3) then
      begin
        Nearby[NearbyCount] := aNewPoly1;
        Inc(NearbyCount);
      end;
  end;

  procedure AddPolygon(var aPPL1, aPPL2: PPolyLine); overload;
  begin
    with fPolygons[fPolyCount] do // Array was filled with 0 bytes in FillChar
    begin
      Indices[0] := aPPL1^.Node;
      Indices[1] := aPPL2^.Node;
      Indices[2] := aPPL2^.Next^.Node;
      ConnectPolygons(fPolyCount, aPPL1^.Polygon);
      ConnectPolygons(fPolyCount, aPPL2^.Polygon);
    end;
    aPPL1^.Polygon := fPolyCount;
    aPPL2^.Polygon := fPolyCount; // Maybe unused (by: NewLine)
    Inc(fPolyCount);
  end;

  function AddPolygon(aIdx: Word; var aPPL: PPolyLine): Word; overload;
  begin
    with fPolygons[fPolyCount] do // Array was filled with 0 bytes in FillChar
    begin
      Indices[0] := aPPL^.Node;
      Indices[1] := aPPL^.Next^.Node;
      Indices[2] := aIdx;
      ConnectPolygons(fPolyCount, aPPL^.Polygon);
    end;
    aPPL^.Polygon := fPolyCount;
    Result := fPolyCount;
    Inc(fPolyCount);
  end;


  function NewLine(aNode: Word; aNext: PPolyLine; aPolygon: Word = 0): PPolyLine;
  begin
    New(Result);
    Result^.Node := aNode;
    Result^.Polygon := aPolygon;
    Result^.Next := aNext;
  end;


  function IsRightSide(P1,P2,Point: TKMPoint): Boolean;
  begin
    Result := ((P2.X - P1.X) * (Point.Y - P1.Y) > (P2.Y - P1.Y) * (Point.X - P1.X));
  end;

  procedure TryConnect(aRemovedNode, aLineIdx: Word; aLeftDirection: Boolean; aBorderPoly: Boolean = False);
  const
    SQR_MAX_RADIUS = 16*16;
  var
    PPoly1, PPoly2, PPoly3: PPolyLine;
  begin
    with LineArray[aLineIdx]^ do
    begin
      if (FirstLine = LastLine) OR (FirstLine^.Next = LastLine) // Only 2 verticles
        OR (FirstLine^.Node = aRemovedNode) OR (LastLine^.Node = aRemovedNode) then // Border node
        Exit;

      PPoly3 := FirstLine;
      PPoly2 := PPoly3^.Next;
      PPoly1 := PPoly2^.Next;
      while (PPoly2.Node <> aRemovedNode) do
      begin
        PPoly3 := PPoly2;
        PPoly2 := PPoly1;
        PPoly1 := PPoly1^.Next;
      end;

      if (KMDistanceSqr(fNodes[ PPoly1^.Node ],fNodes[ PPoly3^.Node ]) > SQR_MAX_RADIUS) then
        Exit;

      if (aBorderPoly AND ( // Force to create polygon in case that it is border point
           (aLeftDirection     AND (fNodes[ PPoly3^.Node ].X > fNodes[ PPoly1^.Node ].X)) OR
           (not aLeftDirection AND (fNodes[ PPoly1^.Node ].X < fNodes[ PPoly3^.Node ].X))
         )) OR IsRightSide(fNodes[ PPoly3^.Node ],fNodes[ PPoly2^.Node ],fNodes[ PPoly1^.Node ]) then
      begin
AddLine(fNodes[ PPoly3^.Node ],fNodes[ PPoly1^.Node ]);
        AddPolygon(PPoly3, PPoly2);
        PPoly3^.Next := PPoly1;
        Dispose(PPoly2); // Remove verticle from memory
        TryConnect( ifthen(aLeftDirection, PPoly1^.Node, PPoly3^.Node), aLineIdx, aLeftDirection, aBorderPoly)
      end;
    end;
  end;

  procedure AddNewBorder(aIdx, aFutureIdx, aLineIdx: Word; aLeftDirection: Boolean; aTryConnect: Boolean = True);
  begin
    ConfirmLine(aIdx, aFutureIdx);
    with LineArray[aLineIdx]^ do
    begin
      if aLeftDirection then
      begin
        FirstLine := NewLine( fBord.Borders[aIdx].Node, FirstLine );
        if aTryConnect then
          TryConnect(fBord.Borders[LeftEdge].Node, aLineIdx, aLeftDirection, True);
        LeftEdge := aIdx;
        FutureLeftEdge := aFutureIdx;
      end
      else
      begin
        LastLine^.Next := NewLine( fBord.Borders[aIdx].Node, nil );
        LastLine := LastLine^.Next;
        if aTryConnect then
          TryConnect(fBord.Borders[RightEdge].Node, aLineIdx, aLeftDirection, True);
        RightEdge := aIdx;
        FutureRightEdge := aFutureIdx;
      end;
    end;
  end;

  procedure DisposeArea(aIdx: Word; aSkipPolyLine: Boolean = False);
  var
    PolyLine, OldPL: PPolyLine;
  begin
    if not aSkipPolyLine then
    begin
      PolyLine := LineArray[aIdx]^.FirstLine;
      while (PolyLine <> LineArray[aIdx]^.LastLine) AND (PolyLine <> nil) do
      begin
        OldPL := PolyLine;
        PolyLine := PolyLine^.Next;
        Dispose(OldPL);
      end;
      Dispose(PolyLine);
    end;
    // Free memory of second lines and update LineArray
    Dispose(LineArray[aIdx]);
    Dec(LineArrayCnt);
    LineArray[aIdx] := LineArray[LineArrayCnt];
  end;

  procedure AddNewWalkableArea(aIdx: Word);
  begin
    // Add new area
    if (Length(LineArray) <= LineArrayCnt) then
      SetLength(LineArray, LineArrayCnt + 20);
    New(LineArray[LineArrayCnt]);
    with LineArray[LineArrayCnt]^ do
    begin
      FirstLine := NewLine(fBord.Borders[aIdx].Node, nil);
      LastLine := FirstLine;
      LeftEdge := aIdx;
      RightEdge := aIdx;
      FutureLeftEdge := fBord.Borders[aIdx].Next;
      FutureRightEdge := fBord.Borders[aIdx].Prev;
ConfirmLine(aIdx, FutureLeftEdge);
ConfirmLine(aIdx, FutureRightEdge);
    end;
    Inc(LineArrayCnt);
  end;

  procedure DivideWalkableArea(aIdx, aLineIdx: Word; aPPrevLine, aPActLine: PPolyLine);
  var
    NewPolyIdx: Word;
  begin
    if (Length(LineArray) <= LineArrayCnt) then
      SetLength(LineArray, LineArrayCnt + 20);
    New(LineArray[LineArrayCnt]);
    // Copy left border from old line
    LineArray[LineArrayCnt]^.FirstLine := LineArray[aLineIdx]^.FirstLine;
    LineArray[LineArrayCnt]^.LeftEdge := LineArray[aLineIdx]^.LeftEdge;
    LineArray[LineArrayCnt]^.FutureLeftEdge := LineArray[aLineIdx]^.FutureLeftEdge;
    if (aPPrevLine = nil) then // Create right border of NEW line if does not exist
    begin
      aPPrevLine := NewLine( aPActLine^.Node, nil );
      LineArray[LineArrayCnt]^.FirstLine := aPPrevLine;
    end
    else if (aPActLine = nil) then // Create left border of OLD line if does not exist
    begin
      aPActLine := NewLine( aPPrevLine^.Node, nil );
      LineArray[aLineIdx]^.LastLine := aPActLine;
    end
    else // Copy the line for the first area + secure connection
    begin
      aPPrevLine^.Next := NewLine( aPActLine^.Node, nil );
      aPPrevLine := aPPrevLine^.Next;
    end;

AddLine2(fNodes[  fBord.Borders[ aIdx ].Node  ], fNodes[ aPPrevLine^.Node ] );
    LineArray[LineArrayCnt]^.LastLine := aPPrevLine;
    AddNewBorder(aIdx, fBord.Borders[aIdx].Prev, LineArrayCnt, False, False);
    NewPolyIdx := fPolyCount; // Polygon with this index does not exist yet
    TryConnect(aPPrevLine.Node, LineArrayCnt, False); // Now multiple new polygons may be created (first one will be connected with second side)

AddLine2(fNodes[  fBord.Borders[ aIdx ].Node  ], fNodes[ aPActLine^.Node ] );
    LineArray[aLineIdx]^.FirstLine := aPActLine;
    AddNewBorder(aIdx, fBord.Borders[aIdx].Next, aLineIdx, True, False);
    // New polygon was created -> copy information to the second area and it will be connected automatically
    if (NewPolyIdx < fPolyCount) then
      LineArray[aLineIdx]^.FirstLine^.Polygon := NewPolyIdx
    else // The polygon was not created -> it will be created from this side -> secure transition
      LineArray[LineArrayCnt]^.LastLine^.Polygon := NewPolyIdx;
    TryConnect(aPActLine.Node, aLineIdx, True);

    Inc(LineArrayCnt);
  end;

  function InsertPoint(aIdx, aLineIdx: Word; aBorder: Boolean): Boolean;
  var
    Point: TKMPoint;
    PPrevLine, PActLine: PPolyLine;
  begin
    // Find relative position of point in stack
    Point := fNodes[ ifthen(aBorder, fBord.Borders[aIdx].Node, aIdx) ];
    PPrevLine := nil;
    PActLine := LineArray[aLineIdx]^.FirstLine;
    repeat
      if (fNodes[ PActLine^.Node ].X >= Point.X ) then
        break;
      PPrevLine := PActLine;
      PActLine := PActLine^.Next;
    until (PActLine = nil);
    // Select the right method -> in case of border point divide area
    if aBorder then
      DivideWalkableArea(aIdx, aLIneIdx, PPrevLine, PActLine)
    else if (PPrevLine <> nil) AND (PActLine <> nil) then // In case of ordinary point just add new element + ignore border points
    begin
AddLine2(fNodes[ aIdx ], fNodes[ PPrevLine^.Node ] );
AddLine2(fNodes[ aIdx ], fNodes[ PActLine^.Node ] );
      PPrevLine^.Next := NewLine(aIdx, PActLine, AddPolygon(aIdx, PPrevLine)); // Add line
      // Try to connect new triangles
      TryConnect(PActLine.Node, aLineIdx, False);
      TryConnect(PPrevLine.Node, aLineIdx, True);
    end;
    Result := True;
  end;

  procedure CheckArea(aIdx: Word; aBorder: Boolean);
  var
    Inserted: Boolean;
    I: Integer;
    Point, LeftP, FutureLeftP, RightP, FutureRightP: TKMPoint;
  begin
    Inserted := False;
    Point := fNodes[ ifthen(aBorder, fBord.Borders[aIdx].Node, aIdx) ];
    // Check point position in area
    for I := 0 to LineArrayCnt - 1 do
    begin
      LeftP :=  fNodes[  fBord.Borders[ LineArray[I]^.LeftEdge ].Node  ];
      RightP := fNodes[  fBord.Borders[ LineArray[I]^.RightEdge ].Node  ];
      FutureLeftP :=  fNodes[  fBord.Borders[ LineArray[I]^.FutureLeftEdge ].Node  ];
      FutureRightP := fNodes[  fBord.Borders[ LineArray[I]^.FutureRightEdge ].Node  ];
      if (  ( Min(RightP.X, FutureRightP.X) >= Point.X ) AND ( Max(LeftP.X, FutureLeftP.X) <= Point.X )  )
        OR (  IsRightSide(FutureLeftP,LeftP,Point) AND IsRightSide(RightP,FutureRightP,Point)  ) then
      begin
        Inserted := InsertPoint(aIdx, I, aBorder);
        break;
      end;
    end;
    if not Inserted AND aBorder then // This must be border point or the point will be ignored
      AddNewWalkableArea(aIdx);
  end;

  procedure RemoveWalkableArea(aIdx, ConIdx: Word);
  begin
ConfirmLine2(aIdx, LineArray[ConIdx]^.LeftEdge);
ConfirmLine2(aIdx, LineArray[ConIdx]^.RightEdge);
    //AddPolygon(fBord.Borders[aIdx].Node, LineArray[ConIdx]^.FirstLine);
    AddNewBorder(aIdx, fBord.Borders[aIdx].Prev, ConIdx, False);
    DisposeArea(ConIdx);
  end;

  procedure MergeWalkableAreas(aIdx, aLeftEdgeLineIdx, aRightEdgeLineIdx: Word);
  begin
ConfirmLine(aIdx, LineArray[aLeftEdgeLineIdx]^.LeftEdge);
ConfirmLine(aIdx, LineArray[aRightEdgeLineIdx]^.RightEdge);
    // Add border points and everything around it
    AddNewBorder(aIdx, aIdx, aLeftEdgeLineIdx, True); // aIdx in second parameter is OK
    AddNewBorder(aIdx, aIdx, aRightEdgeLineIdx, False);
    // Copy border properties
    LineArray[aRightEdgeLineIdx]^.LastLine^.Polygon := LineArray[aLeftEdgeLineIdx]^.FirstLine^.Polygon;
    LineArray[aRightEdgeLineIdx]^.LastLine^.Next :=    LineArray[aLeftEdgeLineIdx]^.FirstLine^.Next; // Next because first point is new border
    LineArray[aRightEdgeLineIdx]^.LastLine :=          LineArray[aLeftEdgeLineIdx]^.LastLine;
    LineArray[aRightEdgeLineIdx]^.RightEdge :=         LineArray[aLeftEdgeLineIdx]^.RightEdge;
    LineArray[aRightEdgeLineIdx]^.FutureRightEdge :=   LineArray[aLeftEdgeLineIdx]^.FutureRightEdge;
    // Free memory of second lines and update LineArray
    Dispose(LineArray[aLeftEdgeLineIdx]^.FirstLine); // Other elements will be copied
    DisposeArea(aLeftEdgeLineIdx, True);
  end;

var
  Y,Idx,K, LeftEdgeLineIdx, RightEdgeLineIdx: Integer;
  PrevY: Integer;
  BorderPoint: TKMPoint;
begin
  fDL.Count := 0;
  fDL2.Count := 0;
  LineArrayCnt := 0;
  PrevY := 0;
  for Y := Low(fBordByY) to High(fBordByY) do
  begin
    Idx := fBordByY[Y];
    while (Idx <> 0) do
      with fBord.Borders[Idx] do
      begin
        BorderPoint := fNodes[Node];

        if (PrevY < BorderPoint.Y-1) then // Add all middle points which are between new and old Y coord
        begin
          for K := fIdxArr[PrevY] to fIdxArr[BorderPoint.Y - 1] - 1 do
            CheckArea(K, False);
          PrevY := BorderPoint.Y-1;
        end;

        LeftEdgeLineIdx := -1;
        RightEdgeLineIdx := -1;
        // Check connection with existing lines
        for K := 0 to LineArrayCnt - 1 do
        begin
          if (LineArray[K]^.FutureLeftEdge = Idx) then
            LeftEdgeLineIdx := K;
          if (LineArray[K]^.FutureRightEdge = Idx) then
            RightEdgeLineIdx := K;
        end;
        // Select the right action and add the point
        if (LeftEdgeLineIdx > -1) AND (RightEdgeLineIdx > -1) then // Border point can merge 2 areas
        begin
          if (LeftEdgeLineIdx = RightEdgeLineIdx) then
            RemoveWalkableArea(Idx, LeftEdgeLineIdx)
          else
            MergeWalkableAreas(Idx, LeftEdgeLineIdx, RightEdgeLineIdx)
        end
        else if (LeftEdgeLineIdx > -1) then // Left border is expanded
          AddNewBorder(Idx, Next, LeftEdgeLineIdx, True)
        else if (RightEdgeLineIdx > -1) then // Right border is expanded
          AddNewBorder(Idx, Prev, RightEdgeLineIdx, False)
        else
          CheckArea(Idx, True);
        Idx := NextY; // Move to next Idx
      end;
  end;

  // Clean mess (only for debug)
  while (LineArrayCnt > 0) do
    DisposeArea(LineArrayCnt - 1);
end;


procedure TKMNavMesh.PrettyPoly();
  function GetCommonPoints(aNode1, aNode2: Word; var CP1,CP2: Word): Boolean;
  var
    I,K: Integer;
  begin
    CP1 := 0;
    for I := 0 to 2 do
      for K := 0 to 2 do
        if (fPolygons[aNode1].Indices[I] = fPolygons[aNode2].Indices[K]) then
        begin
          if (CP1 = 0) then
            CP1 := fPolygons[aNode2].Indices[K]
          else
          begin
            Result := True;
            CP2 := fPolygons[aNode2].Indices[K];
            Exit;
          end;
        end;
  end;

  function AnalyzePoints(aNode1, aNode2: Word; var CP1,CP2,DP1,DP2: Word): Boolean;
  var
    I: Word;
  begin
    Result := GetCommonPoints(aNode1,aNode2, CP1,CP2);
    if Result then
    begin
      with fPolygons[aNode1] do
        for I := 0 to 2 do
          if (CP1 <> Indices[I]) AND (CP2 <> Indices[I]) then
            DP1 := Indices[I];
      with fPolygons[aNode2] do
        for I := 0 to 2 do
          if (CP1 <> Indices[I]) AND (CP2 <> Indices[I]) then
            DP2 := Indices[I];
    end;
  end;

  function OnSegment(aP,aQ,aR: TKMPoint): Boolean;
  begin
  	Result := (aQ.x <= max(aP.x, aR.x)) AND
              (aQ.x >= min(aP.x, aR.x)) AND
  	          (aQ.y <= max(aP.y, aR.y)) AND
              (aQ.y >= min(aP.y, aR.y));
  end;

  function Orientation(aP,aQ,aR: TKMPoint): Integer;
  begin
  	Result := (aQ.y - aP.y) * (aR.x - aQ.x) - (aQ.x - aP.x) * (aR.y - aQ.y);
  	if (Result > 0) then
  		Result := 1 // Clockwise
  	else if (Result < 0) then
  		Result := 2; // Counterclockwise
  end;

  function Intersect(aP1, aQ1, aP2, aQ2: Word): Boolean;
  var
    o1,o2,o3,o4: Integer;
    P1,Q1,P2,Q2: TKMPoint;
  begin
  	Result := False;
    P1 := fNodes[ aP1 ];
    Q1 := fNodes[ aQ1 ];
    P2 := fNodes[ aP2 ];
    Q2 := fNodes[ aQ2 ];
  	// Find the four orientations needed for general and special cases
  	o1 := Orientation(P1, Q1, P2);
  	o2 := Orientation(P1, Q1, Q2);
  	o3 := Orientation(P2, Q2, P1);
  	o4 := Orientation(P2, Q2, Q1);
  	// General case
  	Result := (o1 <> o2) AND (o3 <> o4);
  	// Special Cases
  	if not Result then
  	begin
  		// P1, Q1 and P2 are colinear and P2 lies on segment p1q1
  		if (o1 = 0) AND OnSegment(P1, P2, Q1) then
  			Result := True
  		// P1, Q1 and Q2 are colinear and Q2 lies on segment p1q1
  		else if (o2 = 0) AND OnSegment(P1, Q2, Q1) then
  			Result := True
  		// P2, Q2 and P1 are colinear and P1 lies on segment p2q2
  		else if (o3 = 0) AND OnSegment(P2, P1, Q2) then
  			Result := True
  		// P2, Q2 and Q1 are colinear and Q1 lies on segment p2q2
  		else if (o4 = 0) AND OnSegment(P2, Q1, Q2) then
  			Result := True;
  	end;
  end;

  function HaveIndices(aPolyIdx,aIndice1,aIndice2: Word): Boolean;
  var
    I, Cnt: Word;
  begin
    Cnt := 0;
    with fPolygons[aPolyIdx] do
      for I := 0 to 2 do
        Cnt := Cnt + Byte( (Indices[I] = aIndice1) OR (Indices[I] = aIndice2) );
    Result := Cnt = 2;
  end;

var
  CP1,CP2,DP1,DP2, BestCP1,BestCP2,BestDP1,BestDP2, SwapPoly1, SwapPoly2: Word;
  I,K,L,M, BestIdx, Neat: Integer;
  SqrBestDist, SqrDist: Single;
begin
  for Neat := 0 to 2 do
  for I := 1 to fPolyCount - 1 do
  begin
    SqrBestDist := 0;
    with fPolygons[I] do
      for K := 0 to NearbyCount - 1 do
      begin
        AnalyzePoints(I,Nearby[K],CP1,CP2,DP1,DP2);
        SqrDist := KMDistanceSqr(fNodes[ CP1 ],fNodes[ CP2 ]) - KMDistanceSqr(fNodes[ DP1 ],fNodes[ DP2 ]);
        if (SqrDist > SqrBestDist) AND Intersect(CP1,CP2,DP1,DP2) then
        begin
          SqrBestDist := SqrDist;
          BestCP1 := CP1;
          BestCP2 := CP2;
          BestDP1 := DP1;
          BestDP2 := DP2;
          BestIdx := Nearby[K];
        end;
      end;
    if (SqrBestDist > 0) then
    begin
      // Find indexes of nearby polygons which must be swaped to secure connection
      with fPolygons[I] do
      begin
        for L := 0 to 2 do
          if (Nearby[L] = 0) OR ((Nearby[L] <> BestIdx) AND HaveIndices(Nearby[L], BestCP1, BestDP1)) then
            break;
        SwapPoly1 := Nearby[L];
      end;
      with fPolygons[BestIdx] do
      begin
        for M := 0 to 2 do
          if (Nearby[M] = 0) OR ((Nearby[M] <> I) AND HaveIndices(Nearby[M], BestCP2, BestDP2)) then
            break;
        SwapPoly2 := Nearby[M];
      end;
      // Actualize connection of nearby polygons
      if (SwapPoly1 <> 0) then
        with fPolygons[ SwapPoly1 ] do
          for K := 0 to NearbyCount - 1 do
            if (Nearby[K] = I) then
              Nearby[K] := BestIdx;
      if (SwapPoly2 <> 0) then
        with fPolygons[ SwapPoly2 ] do
          for K := 0 to NearbyCount - 1 do
            if (Nearby[K] = BestIdx) then
              Nearby[K] := I;
      // Actualize connection of changed polygons
      with fPolygons[BestIdx] do
        if (SwapPoly1 <> 0) then
        begin
          Nearby[M] := SwapPoly1;
          NearbyCount := NearbyCount + Byte(SwapPoly2 = 0);
        end
        else
        begin
          NearbyCount := NearbyCount - Byte(SwapPoly2 > 0);
          Nearby[M] := Nearby[NearbyCount];
          Nearby[NearbyCount] := 0; // Zero must be here
        end;
      with fPolygons[I] do
        if (SwapPoly2 <> 0) then
        begin
          Nearby[L] := SwapPoly2;
          NearbyCount := NearbyCount + Byte(SwapPoly1 = 0);
        end
        else
        begin
          NearbyCount := NearbyCount - Byte(SwapPoly1 > 0);
          Nearby[L] := Nearby[NearbyCount];
          Nearby[NearbyCount] := 0;
        end;
      // Change indices
      with fPolygons[I] do
        for K := 0 to 2 do
          if (BestCP1 = Indices[K]) then
            Indices[K] := BestDP2;
      with fPolygons[BestIdx] do
        for K := 0 to 2 do
          if (BestCP2 = Indices[K]) then
            Indices[K] := BestDP1;
    end;
  end;

end;


function TKMNavMesh.GetPolygonFromPoint(const aY,aX: Integer): Word;
begin
  Result := fPoint2PolygonArr[ aY*(fMapX+1) + aX ];
end;

function TKMNavMesh.GetPolygonFromKMPoint(const aPoint: TKMPoint): Word;
begin
  Result := fPoint2PolygonArr[ aPoint.Y*(fMapX+1) + aPoint.X ];
end;


// Find closest NavMesh in case that we get point which is not part of fPoint2PolygonArr
// (stonemason may mine stone and create walkable tiles which are not part of NavMesh [NavMesh is not updated during game])
procedure TKMNavMesh.FindClosestPolygon();
var
  Len,MaxIdx: Word;
  Queue: array[0..255*255] of Integer;
  procedure AddToQueue(aIdx, aPolygon: Integer);
  begin
    Queue[MaxIdx] := aIdx;
    Inc(Len);
    Inc(MaxIdx);
    if (MaxIdx > High(Queue)) then
      MaxIdx := 0;
    fPoint2PolygonArr[aIdx] := aPolygon;
  end;
var
  I,Y,ActIdx: Integer;
begin
  FillChar(Queue, SizeOf(Queue), #0);
  // Mark borders so they do not have to be checked (fPoint2PolygonArr have length fMapX+1 in X and fMapY+1 in Y)
  FillChar(fPoint2PolygonArr[0], SizeOf(Word)*(fMapX+1), #255);
  FillChar(fPoint2PolygonArr[(fMapX+1)*fMapY], SizeOf(Word)*(fMapX+1), #255);
  Y := 0;
  while Y < (fMapX+1) * (fMapY+1) do
  begin
    fPoint2PolygonArr[Y] := High(Word);
    fPoint2PolygonArr[Y + fMapX] := High(Word);
    Y := Y + fMapX+1;
  end;
  // Get all used points
  Len := 0;
  for I := Low(fPoint2PolygonArr) to High(fPoint2PolygonArr) do
    if (fPoint2PolygonArr[I] <> 0) AND (fPoint2PolygonArr[I] <> High(Word)) then
    begin
      Queue[Len] := I;
      Inc(Len);
    end;
  // Expand used points into empty surrounding area
  ActIdx := 0;
  MaxIdx := Len;
  while (Len > 0) do
  begin
    I := Queue[ActIdx];
    Dec(Len);
    Inc(ActIdx);
    if (ActIdx > High(Queue)) then
      ActIdx := 0;
    if (fPoint2PolygonArr[I - 1        ] = 0) then AddToQueue(I - 1        , fPoint2PolygonArr[I]);
    if (fPoint2PolygonArr[I + 1        ] = 0) then AddToQueue(I + 1        , fPoint2PolygonArr[I]);
    if (fPoint2PolygonArr[I - fMapX - 1] = 0) then AddToQueue(I - fMapX - 1, fPoint2PolygonArr[I]);
    if (fPoint2PolygonArr[I + fMapX + 1] = 0) then AddToQueue(I + fMapX + 1, fPoint2PolygonArr[I]);
  end;
end;


procedure TKMNavMesh.TieUpTilesWithPolygons();
  procedure GetNodesSortedByY(aIdx: Integer; var a,b,c: TKMPoint);
  begin
    a := fNodes[ fPolygons[aIdx].Indices[0] ];
    b := fNodes[ fPolygons[aIdx].Indices[1] ];
    c := fNodes[ fPolygons[aIdx].Indices[2] ];
    if (a.Y > b.Y) then KMSwapPoints(a,b);
    if (b.Y > c.Y) then KMSwapPoints(b,c);
    if (a.Y > b.Y) then KMSwapPoints(a,b);
  end;
  procedure NormalLineEquation(P1,P2: TKMPoint; var a,b,c: Single);
  begin
    a := - P1.Y + P2.Y;
    b := + P1.X - P2.X;
    c := - a * (P1.X + 0.5) - b * (P1.Y + 0.5); // + 0.5 will move triangle by 1/2 of tile in right down direction
  end;
  function IsRightSide(P1,P2,Point: TKMPoint): Boolean;
  begin
    Result := ((P2.X - P1.X) * (Point.Y - P1.Y) < (P2.Y - P1.Y) * (Point.X - P1.X));
  end;
  procedure FillTriangle(RightSide: Boolean; aIdx, StartY,EndY: Integer; a1,b1,c1, a2,b2,c2: Single);
  var
    X,Y: Integer;
    invA1,invA2, X1, X2: Single;
  begin
    if (a1 = 0) OR (a2 = 0) then
      Exit;
    invA1 := 1 / (a1*1.0); // a*X + b*Y + c = 0  ->  X = (- b*Y - c) * (1/a)  ->  X = C1*Y + C2
    invA2 := 1 / (a2*1.0);
    for Y := StartY to EndY do
    begin
      X1 := (- b1*Y - c1) * invA1 + 0.499;
      X2 := (- b2*Y - c2) * invA2;
      if not RightSide then
        KMSwapFloat(X1,X2);
      for X := Round( X1 ) to Trunc( X2 ) do
        fPoint2PolygonArr[ Y*(fMapX+1) + X ] := aIdx; // Property does not have write attribute
    end;
  end;
  procedure ComputeNearbyPoints(aIdx: Word);
  var
    SecondPoint: Boolean;
    I,K,L, ToIdx: Integer;
    P: TKMPoint;
    Indices: array[0..1] of Word;
  begin
    for I := 0 to fPolygons[aIdx].NearbyCount - 1 do
    begin
      SecondPoint := False;
      ToIdx := fPolygons[aIdx].Nearby[I];
      for K := 0 to 2 do
      for L := 0 to 2 do
        if (fPolygons[aIdx].Indices[K] = fPolygons[ToIdx].Indices[L]) then
        begin
          Indices[ Byte(SecondPoint) ] := fPolygons[aIdx].Indices[K];
          SecondPoint := True;
          break;
        end;
       P := KMPointAverage(fNodes[ Indices[0] ], fNodes[ Indices[1] ]);
       fPolygons[aIdx].NearbyPoints[I] := KMPoint(  Min( fMapX-1, Max(1,P.X) ), Min( fMapY-1, Max(1,P.Y) )  );
    end;
  end;
var
  RightSide: Boolean;
  I: Integer;
  a1,b1,c1, a2,b2,c2, a3,b3,c3: Single;
  N1,N2,N3: TKMPoint;
begin
  SetLength(fPoint2PolygonArr, (fMapY+1) * (fMapX+1));
  FillChar(fPoint2PolygonArr[0], SizeOf(fPoint2PolygonArr[0]) * Length(fPoint2PolygonArr), #0); // 0 Is unused polygon
  for I := 1 to fPolyCount - 1 do
  begin
    // Fill fPoint2PolygonArr
    GetNodesSortedByY(I, N1,N2,N3);
    RightSide := IsRightSide(N1,N3,N2);
    NormalLineEquation(N1,N3, a1,b1,c1);
    NormalLineEquation(N1,N2, a2,b2,c2);
    NormalLineEquation(N2,N3, a3,b3,c3);
    FillTriangle(RightSide, I, N1.Y,N2.Y,   a1,b1,c1, a2,b2,c2); // Skip last line if second part is active
    FillTriangle(RightSide, I, N2.Y+1,N3.Y, a1,b1,c1, a3,b3,c3);
    // Fill another polygon informations
    // Center point must be inside of map coords
    fPolygons[I].CenterPoint := KMPoint(
                                         Min(  fMapX-1, Max( 1, Round((N1.X+N2.X+N3.X)/3) )  ),
                                         Min(  fMapY-1, Max( 1, Round((N1.Y+N2.Y+N3.Y)/3) )  )
                                       );
    ComputeNearbyPoints(I);
  end;
  FindClosestPolygon();
end;


procedure TKMNavMesh.TieUpPolygonsWithTiles();
//var
//  X,Y,Polygon: Integer;
begin
  {
  // Get count of points in specific polygon
  for Y := 1 to fMapY-1 do
  for X := 1 to fMapX-1 do
    Inc(fPolygons[ Point2Polygon[Y,X] ].Poly2PointCnt); // Poly2PointCnt was set to 0 in initialization
  // Get starting index of each polygon
  for X := 1 to fPolyCount - 1 do // 0. polygon is reserved / unused
    fPolygons[X].Poly2PointStart := fPolygons[X-1].Poly2PointStart + fPolygons[X-1].Poly2PointCnt;
  // Fill points in 1D array which is common for all polygons
  SetLength(fPolygon2PointArr,(fMapX-1) * (fMapY-1));
  for Y := 1 to fMapY-1 do
  for X := 1 to fMapX-1 do
  begin
    Polygon := Point2Polygon[Y,X];
    fPolygon2PointArr[  fPolygons[Polygon].Poly2PointStart  ] := KMPoint(X,Y);
    Inc(fPolygons[Polygon].Poly2PointStart);
  end;
  // Get starting index of each polygon
  for X := 1 to fPolyCount - 1 do // 0. polygon is reserved / unused
    fPolygons[X].Poly2PointStart := fPolygons[X-1].Poly2PointStart + fPolygons[X-1].Poly2PointCnt;
  //}
end;





//Render debug symbols
procedure TKMNavMesh.Paint(const aRect: TKMRect);
const
  COLOR_WHITE = $FFFFFF;
  COLOR_BLACK = $000000;
  COLOR_GREEN = $00FF00;
  COLOR_RED = $8000FF;
  COLOR_YELLOW = $00FFFF;
  COLOR_BLUE = $FF0000;

  function GetCommonPoints(aIdx1, aIdx2: Word; var aPoint1, aPoint2: TKMPoint): Boolean;
  var
    FirstPoint: Boolean;
    I,K: Integer;
  begin
    Result := False;
    FirstPoint := True;
    for I := 0 to 2 do
    for K := 0 to 2 do
      if (fPolygons[aIdx1].Indices[I] = fPolygons[aIdx2].Indices[K]) then
      begin
        if FirstPoint then
          aPoint1 := fNodes[ fPolygons[aIdx2].Indices[K] ]
        else
        begin
          aPoint2 := fNodes[ fPolygons[aIdx2].Indices[K] ];
          Result := True;
          Exit;
        end;
        FirstPoint := False;
      end;
  end;
var
  I, K: Integer;
  p1,p2,p3: TKMPoint;

  W: Word;
  Owner: TKMHandIndex;
  DefLines: TKMDefenceLines;
  DefencePosArr: TKMDefencePosArr;
  FFF: TForwardFF;
begin
  if not AI_GEN_NAVMESH OR not OVERLAY_NAVMESH then
    Exit;
  //AfterMissionInit();

  // EXTRACT POLYGONS
  //{ Border Lines
  for I := 0 to fBord.Count - 1 do
    with fBord.Borders[I] do
    begin
      p1 := fNodes[ Node ];
      p2 := fNodes[  fBord.Borders[ Next ].Node  ];
      p3 := fNodes[  fBord.Borders[ Prev ].Node  ];
      gRenderAux.LineOnTerrain(p1, p2, $40000000 OR COLOR_RED);
      gRenderAux.LineOnTerrain(p1, p3, $40000000 OR COLOR_RED);
    end;//}
  { Nodes
  for I := 0 to fInnerPointStartIdx - 1 do
      gRenderAux.Quad(fNodes[I].X, fNodes[I].Y, $80000000 OR COLOR_RED);
  for I := fInnerPointStartIdx to fInnerPointEndIdx do
      gRenderAux.Quad(fNodes[I].X, fNodes[I].Y, $A0000000 OR COLOR_YELLOW);//}

  // TRIANGULATION
  { Debug lines of triangulation
  for I := 0 to fDL.Count - 1 do
      gRenderAux.LineOnTerrain(fDL.Lines[I].p1, fDL.Lines[I].p2, $40000000 OR COLOR_RED);
  for I := 0 to fDL2.Count - 1 do
      gRenderAux.LineOnTerrain(fDL2.Lines[I].p1, fDL2.Lines[I].p2, $40000000 OR COLOR_BLACK);//}
  //{ Triangles and connection of NavMesh
  for I := 1 to fPolyCount - 1 do
    with fPolygons[I] do
    begin
      gRenderAux.TriangleOnTerrain(
        fNodes[ Indices[0] ].X,
        fNodes[ Indices[0] ].Y,
        fNodes[ Indices[1] ].X,
        fNodes[ Indices[1] ].Y,
        fNodes[ Indices[2] ].X,
        fNodes[ Indices[2] ].Y, $50000000 OR COLOR_BLACK);
      for K := 0 to NearbyCount - 1 do
        if GetCommonPoints(I, Nearby[K], p1, p2) then
          gRenderAux.LineOnTerrain(p1, p2, $80000000 OR COLOR_BLUE)
        else
        begin
          gRenderAux.TriangleOnTerrain(
            fNodes[ Indices[0] ].X,
            fNodes[ Indices[0] ].Y,
            fNodes[ Indices[1] ].X,
            fNodes[ Indices[1] ].Y,
            fNodes[ Indices[2] ].X,
            fNodes[ Indices[2] ].Y, $50000000 OR COLOR_WHITE);
        end;
      p1.X := Round( (fNodes[ Indices[0] ].X + fNodes[ Indices[1] ].X + fNodes[ Indices[2] ].X) / 3 );
      p1.Y := Round( (fNodes[ Indices[0] ].Y + fNodes[ Indices[1] ].Y + fNodes[ Indices[2] ].Y) / 3 );
      gRenderAux.Text(p1.X, p1.Y + 1, IntToStr(I), $FFFFFFFF);
    end;//}
  { Center points and transitions of polygons
  for I := 0 to fPolyCount - 1 do
    with fPolygons[I] do
    begin
      gRenderAux.Quad(CenterPoint.X, CenterPoint.Y, $AAFFFFFF);
      for K := 0 to NearbyCount - 1 do
        gRenderAux.Quad(NearbyPoints[K].X, NearbyPoints[K].Y, $AA000000);
    end;//}

  //{ DEFENCE SYSTEM
  // Show this defences only in case that show combat AI is not enabled;
  // when it is we need existing results not the actual (defences are updated each 1 min so it may be different)
  if OVERLAY_NAVMESH AND OVERLAY_DEFENCES AND not OVERLAY_AI_COMBAT then
  begin
    Owner := gMySpectator.HandIndex;
    FFF := TForwardFF.Create(true);
    try
      if FFF.FindDefenceLines(Owner, DefLines) then
        for K := 0 to DefLines.Count - 1 do
        begin
          I := DefLines.Lines[K].Polygon;
          gRenderAux.TriangleOnTerrain(
            fNodes[fPolygons[I].Indices[0]].X,
            fNodes[fPolygons[I].Indices[0]].Y,
            fNodes[fPolygons[I].Indices[1]].X,
            fNodes[fPolygons[I].Indices[1]].Y,
            fNodes[fPolygons[I].Indices[2]].X,
            fNodes[fPolygons[I].Indices[2]].Y, $300000FF);
        end;
      W := 20;
      if FFF.FindDefensivePolygons(Owner, W, DefencePosArr, False) then
        for K := 0 to Length(DefencePosArr) - 1 do
        begin
          p1 := DefencePosArr[K].DirPoint.Loc;
          gRenderAux.CircleOnTerrain(p1.X, p1.Y, 2, $0900FFFF, $FFFFFFFF);
        end;
    finally
      FFF.Free;
    end;
  end;//}
end;


end.
