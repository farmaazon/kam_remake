unit KM_Viewport;
{$I KaM_Remake.inc}
interface
uses
  {$IFDEF MSWINDOWS} Windows, {$ENDIF}
  KM_CommonClasses, KM_Points;


type
  TKMViewport = class
  private
    fMapX, fMapY: Word;
    fTopHill: Single;
    fPosition: TKMPointF;
    fScrolling: Boolean;
    fScrollStarted: Cardinal;
    fViewportClip: TPoint;
    fViewRect: TKMRect;
    fZoom: Single;
    fPanTo, fPanFrom: TKMPointF;
    fPanImmidiately : Boolean;
    fPanDuration, fPanProgress: Cardinal;
    fToolBarWidth : Integer;
    function GetPosition: TKMPointF;
    procedure SetPosition(const Value: TKMPointF);
    procedure SetZoom(aZoom: Single);
  public
    ScrollKeyLeft, ScrollKeyRight, ScrollKeyUp, ScrollKeyDown, ZoomKeyIn, ZoomKeyOut: boolean;
    constructor Create(aToolBarWidth: Integer; aWidth, aHeight: Integer);

    property Position: TKMPointF read GetPosition write SetPosition;
    property Scrolling: Boolean read fScrolling;
    property ViewportClip: TPoint read fViewportClip;
    property ViewRect: TKMRect read fViewRect;
    property Zoom: Single read fZoom write SetZoom;

    procedure ResetZoom;
    procedure Resize(NewWidth, NewHeight: Integer);
    procedure ResizeMap(aMapX, aMapY: Word; aTopHill: Single);
    function GetClip: TKMRect; //returns visible area dimensions in map space
    function GetMinimapClip: TKMRect;
    procedure ReleaseScrollKeys;
    procedure GameSpeedChanged(aFromSpeed, aToSpeed: Single);
    function MapToScreen(const aMapLoc: TKMPointF): TKMPoint;
    procedure PanTo(const aLoc: TKMPointF; aTicksCnt: Cardinal);
    procedure CinematicReset;

    procedure Save(SaveStream: TKMemoryStream);
    procedure Load(LoadStream: TKMemoryStream);

    procedure UpdateStateIdle(aFrameTime: Cardinal; aAllowMouseScrolling: Boolean; aInCinematic: Boolean);
    function ToStr: string;
  end;


implementation
uses
  Math, KromUtils,
  KM_Resource, KM_ResCursors,
  KM_Main, KM_GameApp, KM_GameSettings, KM_Sound,
  KM_Defaults, KM_CommonUtils;


{ TKMViewport }
constructor TKMViewport.Create(aToolBarWidth: Integer; aWidth, aHeight: Integer);
begin
  inherited Create;

  fToolBarWidth := aToolBarWidth;

  fMapX := 1; //Avoid division by 0
  fMapY := 1; //Avoid division by 0

  CinematicReset;

  fZoom := 1;
  ReleaseScrollKeys;
  gSoundPlayer.UpdateListener(fPosition.X, fPosition.Y);
  if gScriptSounds <> nil then
    gScriptSounds.UpdateListener(fPosition.X, fPosition.Y);
  Resize(aWidth, aHeight);
end;


procedure TKMViewport.SetZoom(aZoom: Single);
begin
  fZoom := EnsureRange(aZoom, 0.01, 8);
  //Limit the zoom to within the map boundaries
  if fViewportClip.X/CELL_SIZE_PX/fZoom > fMapX then fZoom := fViewportClip.X/CELL_SIZE_PX/(fMapX-1);
  if fViewportClip.Y/CELL_SIZE_PX/fZoom > fMapY then fZoom := fViewportClip.Y/CELL_SIZE_PX/ fMapY;
  SetPosition(fPosition); //To ensure it sets the limits smoothly
end;


procedure TKMViewport.ResetZoom;
begin
  Zoom := 1;
end;


procedure TKMViewport.Resize(NewWidth, NewHeight: Integer);
begin
  fViewRect.Left   := fToolBarWidth;
  fViewRect.Top    := 0;
  fViewRect.Right  := NewWidth;
  fViewRect.Bottom := NewHeight;

  fViewportClip.X := fViewRect.Right-fViewRect.Left;
  fViewportClip.Y := fViewRect.Bottom-fViewRect.Top;

  SetZoom(fZoom); //View size has changed and that affects Zoom restrictions
end;


procedure TKMViewport.ResizeMap(aMapX, aMapY: Word; aTopHill: Single);
begin
  fMapX := aMapX;
  fMapY := aMapY;
  fTopHill := aTopHill;
  SetPosition(fPosition); //EnsureRanges
end;


function TKMViewport.GetPosition: TKMPointF;
begin
  Result.X := EnsureRange(fPosition.X, 1, fMapX);
  Result.Y := EnsureRange(fPosition.Y, 1, fMapY);
end;


procedure TKMViewport.SetPosition(const Value: TKMPointF);
var
  padTop, tilesX, tilesY: Single;
begin
  padTop := fTopHill + 0.75; //Leave place on top for highest hills + 1 unit

  tilesX := fViewportClip.X/2/CELL_SIZE_PX/fZoom;
  tilesY := fViewportClip.Y/2/CELL_SIZE_PX/fZoom;

  fPosition.X := EnsureRange(Value.X, tilesX, fMapX - tilesX - 1);
  fPosition.Y := EnsureRange(Value.Y, tilesY - padTop, fMapY - tilesY - 1); //Top row should be visible
  gSoundPlayer.UpdateListener(fPosition.X, fPosition.Y);
  if gScriptSounds <> nil then
    gScriptSounds.UpdateListener(fPosition.X, fPosition.Y);
end;


//Acquire boundaries of area visible to user (including mountain tops from the lower tiles)
//TestViewportClipInset is for debug, allows to see if everything gets clipped correct
function TKMViewport.GetClip: TKMRect;
begin
  Result.Left   := Math.Max(Round(fPosition.X
                         - (fViewportClip.X/2 - fViewRect.Left + fToolBarWidth) / CELL_SIZE_PX / fZoom), 1);
  Result.Right  := Math.Min(Round(fPosition.X
                         + (fViewportClip.X/2 + fViewRect.Left - fToolBarWidth) / CELL_SIZE_PX / fZoom) + 1, fMapX - 1);
  //Small render problem could be encountered at the top of clip rect
  //This small problem could be seen with reshade app (with displaydepth filter ON)
  //Enlarge clip viewport by 1 to fix it
  Result.Top    := Math.Max(Round(fPosition.Y
                         - fViewportClip.Y/2 / CELL_SIZE_PX / fZoom) - 1, 1); // - 1 to update clip rect to the top on scroll
  Result.Bottom := Math.Min(Round(fPosition.Y
                         + fViewportClip.Y/2 / CELL_SIZE_PX / fZoom) + 5, fMapY - 1); // + 5 for high trees

  if TEST_VIEW_CLIP_INSET then
    Result := KMRectGrow(Result, -5);
end;


//Same as above function but with some values changed to suit minimap
function TKMViewport.GetMinimapClip: TKMRect;
begin
  Result.Left   := Math.max(round(fPosition.X-(fViewportClip.X/2-fViewRect.Left+fToolBarWidth)/CELL_SIZE_PX/fZoom)+1, 1);
  Result.Right  := Math.min(round(fPosition.X+(fViewportClip.X/2+fViewRect.Left-fToolBarWidth)/CELL_SIZE_PX/fZoom)+1, fMapX);
  Result.Top    := Math.max(round(fPosition.Y-fViewportClip.Y/2/CELL_SIZE_PX/fZoom)+2, 1);
  Result.Bottom := Math.min(round(fPosition.Y+fViewportClip.Y/2/CELL_SIZE_PX/fZoom), fMapY);
end;


procedure TKMViewport.ReleaseScrollKeys;
begin
  ScrollKeyLeft  := false;
  ScrollKeyRight := false;
  ScrollKeyUp    := false;
  ScrollKeyDown  := false;
  ZoomKeyIn      := false;
  ZoomKeyOut     := false;
end;


procedure TKMViewport.GameSpeedChanged(aFromSpeed, aToSpeed: Single);
var
  koef: Single;
begin
  if (aFromSpeed > 0) and (fPanDuration > 0) and not fPanImmidiately then
  begin
    //Update PanDuration and Progress due to new game speed
    koef := aFromSpeed / aToSpeed;
    fPanDuration := Round((fPanDuration - fPanProgress) * koef);
    fPanProgress := Round(fPanProgress * koef);
    Inc(fPanDuration, fPanProgress);
  end;
end;


function TKMViewport.MapToScreen(const aMapLoc: TKMPointF): TKMPoint;
begin
  Result.X := Round((aMapLoc.X - fPosition.X) * CELL_SIZE_PX * fZoom + fViewRect.Right / 2 + fToolBarWidth / 2);
  Result.Y := Round((aMapLoc.Y - fPosition.Y) * CELL_SIZE_PX * fZoom + fViewRect.Bottom / 2);
end;


procedure TKMViewport.PanTo(const aLoc: TKMPointF; aTicksCnt: Cardinal);
begin
  fPanTo := aLoc;
  fPanFrom := fPosition;
  fPanImmidiately := aTicksCnt = 0;
  fPanProgress := 0;
  fPanDuration := Round(aTicksCnt * gGameApp.Game.TickDuration);
  //Panning will be skipped when duration is zero
  if fPanImmidiately then
    SetPosition(aLoc);
end;


procedure TKMViewport.CinematicReset;
begin
  fPanFrom := KMPOINTF_INVALID_TILE;
  fPanTo := KMPOINTF_INVALID_TILE;
end;


//Here we must test each edge to see if we need to scroll in that direction
//We scroll at SCROLLSPEED per 100 ms. That constant is defined in KM_Defaults
procedure TKMViewport.UpdateStateIdle(aFrameTime: Cardinal; aAllowMouseScrolling: Boolean; aInCinematic: Boolean);
const
  SCROLL_ACCEL_TIME = 400; // Time in ms that scrolling will be affected by acceleration
  SCROLL_FLEX = 4;         // Number of pixels either side of the edge of the screen which will count as scrolling
  DIRECTIONS_BITFIELD: array [0..15] of TKMCursor = (
    kmcDefault, kmcScroll6, kmcScroll0, kmcScroll7,
    kmcScroll2, kmcDefault, kmcScroll1, kmcDefault,
    kmcScroll4, kmcScroll5, kmcDefault, kmcDefault,
    kmcScroll3, kmcDefault, kmcDefault, kmcDefault);

  function PanPointsAreValid: Boolean;
  begin
    Result := (fPanFrom <> KMPOINTF_INVALID_TILE)
          and (fPanTo   <> KMPOINTF_INVALID_TILE);
  end;

var
  I: Byte;
  timeSinceStarted: Cardinal;
  scrollAdv, zoomAdv: Single;
  cursorPoint: TKMPoint;
  screenBounds: TRect;
  mousePos: TPoint;
begin
  //Cinematics do not allow normal scrolling. The camera will be set and panned with script commands
  if aInCinematic then
  begin
    if not fPanImmidiately and PanPointsAreValid then //Do not move viewport if pan points are not valid
    begin
      Inc(fPanProgress, aFrameTime);
      if fPanProgress >= fPanDuration then
      begin
        SetPosition(fPanTo); //Pan ended
        fPanImmidiately := True; //Not panning
        fPanDuration := 0;
      end
      else
        SetPosition(KMLerp(fPanFrom, fPanTo, fPanProgress / fPanDuration));
    end;
    Exit;
  end;

  {$IFDEF MSWindows}
    //Don't use Mouse.CursorPos, it will throw an EOSError (code 5: access denied) in some cases when
    //the OS doesn't want us controling the mouse, or possibly when the mouse is reset in some way.
    //It happens for me in Windows 7 every time I press CTRL+ALT+DEL with the game running.
    //On Windows XP I get "call to an OS function failed" instead.
    if not Windows.GetCursorPos(mousePos) then Exit;
  {$ENDIF}
  {$IFDEF Unix}
    MousePos := Mouse.CursorPos;
  {$ENDIF}
  if not gMain.GetScreenBounds(screenBounds) then Exit;

  //With multiple monitors the cursor position can be outside of this screen, which makes scrolling too fast
  cursorPoint.X := EnsureRange(mousePos.X, screenBounds.Left, screenBounds.Right );
  cursorPoint.Y := EnsureRange(mousePos.Y, screenBounds.Top , screenBounds.Bottom);

  //Do not do scrolling when the form is not focused (player has switched to another application)
  if not aAllowMouseScrolling or
     not gMain.IsFormActive or
    (not ScrollKeyLeft  and
     not ScrollKeyUp    and
     not ScrollKeyRight and
     not ScrollKeyDown  and
     not ZoomKeyIn      and
     not ZoomKeyOut     and
     not (cursorPoint.X <= screenBounds.Left + SCROLL_FLEX) and
     not (cursorPoint.Y <= screenBounds.Top + SCROLL_FLEX) and
     not (cursorPoint.X >= screenBounds.Right -1-SCROLL_FLEX) and
     not (cursorPoint.Y >= screenBounds.Bottom-1-SCROLL_FLEX)) then
  begin
    //Stop the scrolling (e.g. if the form loses focus due to other application popping up)
    ReleaseScrollKeys;
    fScrolling := False;

    if (gRes.Cursors.Cursor in [kmcScroll0 .. kmcScroll7]) then
      gRes.Cursors.Cursor := kmcDefault;

    fScrollStarted := 0;
    Exit;
  end;

  // Both advancements have minimal value > 0
  // ScrollAdv depends on Zoom. Value was taken empirically
  scrollAdv := (0.5 + gGameSettings.ScrollSpeed / 5) * aFrameTime / 100 / Math.Power(fZoom, 0.8);

  zoomAdv := (0.2 + gGameSettings.ScrollSpeed / 20) * aFrameTime / 1000;

  if SCROLL_ACCEL then
  begin
    if fScrollStarted = 0 then
      fScrollStarted := TimeGet;
    timeSinceStarted := TimeSince(fScrollStarted);
    if timeSinceStarted < SCROLL_ACCEL_TIME then
      scrollAdv := Mix(scrollAdv, 0, timeSinceStarted / SCROLL_ACCEL_TIME);
  end;

  I := 0; //That is our bitfield variable for directions, 0..12 range
  //    3 2 6  These are directions
  //    1 * 4  They are converted from bitfield to actual cursor constants, see Arr array
  //    9 8 12

  //Keys
  if ScrollKeyLeft  then fPosition.X := fPosition.X - scrollAdv;
  if ScrollKeyUp    then fPosition.Y := fPosition.Y - scrollAdv;
  if ScrollKeyRight then fPosition.X := fPosition.X + scrollAdv;
  if ScrollKeyDown  then fPosition.Y := fPosition.Y + scrollAdv;
  if ZoomKeyIn      then fZoom := fZoom * (1 + zoomAdv);
  if ZoomKeyOut     then fZoom := fZoom * (1 - zoomAdv);
  //Mouse
  if cursorPoint.X <= screenBounds.Left   + SCROLL_FLEX then begin inc(I,1); fPosition.X := fPosition.X - scrollAdv*(1+(screenBounds.Left   - cursorPoint.X)/SCROLL_FLEX); end;
  if cursorPoint.Y <= screenBounds.Top    + SCROLL_FLEX then begin inc(I,2); fPosition.Y := fPosition.Y - scrollAdv*(1+(screenBounds.Top    - cursorPoint.Y)/SCROLL_FLEX); end;
  if cursorPoint.X >= screenBounds.Right -1-SCROLL_FLEX then begin inc(I,4); fPosition.X := fPosition.X + scrollAdv*(1-(screenBounds.Right -1-cursorPoint.X)/SCROLL_FLEX); end;
  if cursorPoint.Y >= screenBounds.Bottom-1-SCROLL_FLEX then begin inc(I,8); fPosition.Y := fPosition.Y + scrollAdv*(1-(screenBounds.Bottom-1-cursorPoint.Y)/SCROLL_FLEX); end;

  //Now do actual the scrolling, if needed
  fScrolling := I <> 0;
  if fScrolling then
    gRes.Cursors.Cursor := DIRECTIONS_BITFIELD[I] //Sample cursor type from bitfield value
  else
    if (gRes.Cursors.Cursor in [kmcScroll0 .. kmcScroll7]) then
      gRes.Cursors.Cursor := kmcDefault;

  SetZoom(fZoom); //EnsureRanges
  SetPosition(fPosition); //EnsureRanges
end;


procedure TKMViewport.Save(SaveStream: TKMemoryStream);
begin
  SaveStream.PlaceMarker('Viewport');
  SaveStream.Write(fMapX);
  SaveStream.Write(fMapY);
  SaveStream.Write(fPosition);
  //Zoom is reset to 1 by default
end;


procedure TKMViewport.Load(LoadStream: TKMemoryStream);
begin
  LoadStream.CheckMarker('Viewport');
  //Load map dimensions then Position so it could be fit to map
  LoadStream.Read(fMapX);
  LoadStream.Read(fMapY);
  LoadStream.Read(fPosition);

  SetPosition(fPosition); //EnsureRanges
end;


function TKMViewport.ToStr: string;
begin
  Result := Format('Pos = %s; Zoom = %s ViewClip = (%d; %d) ViewRect = %s', [
                   fPosition.ToString, FormatFloat('0.###', fZoom), fViewportClip.X, fViewportClip.Y, fViewRect.ToString]);
end;


end.
