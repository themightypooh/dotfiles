namespace FishFlop;

/// <summary>
/// The whole game: a half-full, open-top tank. The fist pushes water and hits fish:
/// launch them out of the water, then keep them in the air with more hits (combo)
/// until they come apart. Hold left mouse to clench (stronger), right mouse punches
/// a shockwave, R refills. Needs the scene's physics mode set to 2D (tank.scene does this).
/// </summary>
public sealed class TankGame : Component
{
	public Fluid Fluid { get; private set; }
	public Plants Plants { get; private set; }
	public IReadOnlyList<Fish> AllFish => _fish;

	readonly List<Fish> _fish = new();
	readonly Random _rng = new( 12345 );
	TankRenderer _renderer;
	SceneCustomObject _sceneObject;
	CameraComponent _camera;
	readonly FistCursor _cursor = new();

	Vector2 _mousePrev;
	bool _hasMousePrev;
	bool _punchQueued;
	Vector2 _fistVel;

	const float FistRadius = 26f;
	const float CameraHeight = 1300f;
	static readonly Vector2 CameraCenter = new( 0, 50 );
	float _shake;

	// combo readout
	string _comboText;
	float _comboShow;
	Vector2 _comboAt;
	int _bestCombo;

	protected override void OnStart()
	{
		Mouse.Visibility = MouseVisibility.Visible;
		Mouse.CursorType = "none"; // we draw the fist ourselves

		CreateCamera();
		CreateStaticGeometry();

		Fluid = new Fluid();
		Plants = new Plants( _rng );
		SpawnFish();

		_renderer = new TankRenderer( _rng );
		_sceneObject = new SceneCustomObject( Scene.SceneWorld );
		_sceneObject.Flags.IsOpaque = false;
		_sceneObject.Flags.IsTranslucent = true;
		_sceneObject.RenderOverride = _renderer.Render;
	}

	protected override void OnDestroy()
	{
		_sceneObject?.Delete();
		_sceneObject = null;
	}

	void CreateCamera()
	{
		var go = Scene.CreateObject();
		go.Name = "Camera";
		go.WorldPosition = new Vector3( CameraCenter.x, CameraCenter.y, 1000 );
		go.WorldRotation = Rotation.LookAt( Vector3.Down, new Vector3( 0, 1, 0 ) ); // look into the tank, +Y up
		_camera = go.Components.Create<CameraComponent>();
		_camera.Orthographic = true;
		_camera.OrthographicHeight = CameraHeight;
		_camera.ZNear = 10;
		_camera.ZFar = 5000;
		_camera.BackgroundColor = new Color( 0.13f, 0.12f, 0.13f );
		_camera.IsMainCamera = true;
	}

	void CreateStaticGeometry()
	{
		var w = Tank.WallThickness;
		var width = Tank.Right - Tank.Left;
		Box( "Tank floor", new Vector2( 0, Tank.Bottom - w * 0.5f ), new Vector2( width + 2 * w, w ) );
		Box( "Gravel", new Vector2( 0, (Tank.Bottom + Tank.GravelTop) * 0.5f ), new Vector2( width, Tank.GravelTop - Tank.Bottom ) );
		// open top: the glass stops at the rim
		var glassH = Tank.Rim - Tank.Bottom + w;
		Box( "Left glass", new Vector2( Tank.Left - w * 0.5f, Tank.Bottom - w + glassH * 0.5f ), new Vector2( w, glassH ) );
		Box( "Right glass", new Vector2( Tank.Right + w * 0.5f, Tank.Bottom - w + glassH * 0.5f ), new Vector2( w, glassH ) );

		// the room: stand under the tank, floor, walls, ceiling. Fish that fly out land here.
		Box( "Stand", new Vector2( 0, (Tank.StandTop + Tank.Floor) * 0.5f ), new Vector2( Tank.StandHalfWidth * 2, Tank.StandTop - Tank.Floor ) );
		Box( "Floor", new Vector2( 0, Tank.Floor - 50 ), new Vector2( Tank.RoomHalfWidth * 2 + 200, 100 ) );
		Box( "Ceiling", new Vector2( 0, Tank.Ceiling + 50 ), new Vector2( Tank.RoomHalfWidth * 2 + 200, 100 ) );
		var roomH = Tank.Ceiling - Tank.Floor;
		Box( "Left wall", new Vector2( -Tank.RoomHalfWidth - 50, (Tank.Ceiling + Tank.Floor) * 0.5f ), new Vector2( 100, roomH ) );
		Box( "Right wall", new Vector2( Tank.RoomHalfWidth + 50, (Tank.Ceiling + Tank.Floor) * 0.5f ), new Vector2( 100, roomH ) );

		var rock = Scene.CreateObject();
		rock.Name = "Rock arch";
		rock.WorldPosition = new Vector3( Tank.ArchBase.x, Tank.ArchBase.y, 0 );
		foreach ( var piece in Tank.ArchPieces )
		{
			var hull = rock.Components.Create<HullCollider>( false );
			hull.Type = HullCollider.PrimitiveType.Points;
			hull.Points = piece.Select( p => new Vector3( p.x, p.y, 0 ) ).ToList();
			hull.Static = true;
			hull.Friction = 0.6f;
			hull.Enabled = true;
		}
	}

	void Box( string name, Vector2 center, Vector2 size )
	{
		var go = Scene.CreateObject();
		go.Name = name;
		go.WorldPosition = new Vector3( center.x, center.y, 0 );
		var box = go.Components.Create<BoxCollider>( false );
		box.Scale = new Vector3( size.x, size.y, 100 );
		box.Static = true;
		box.Friction = 0.6f;
		box.Enabled = true;
	}

	void SpawnFish()
	{
		var layout = new (FishSpec spec, float x, float y, int facing)[]
		{
			(FishSpec.Goldie, -480, -120, 1),
			(FishSpec.Goldie, 150, -170, -1),
			(FishSpec.Goldie, -100, -330, 1),
			(FishSpec.Mackerel, -250, -80, 1),
			(FishSpec.Mackerel, 430, -90, -1),
			(FishSpec.Tang, -600, -300, 1),
			(FishSpec.Tang, 600, -250, -1),
			(FishSpec.Tang, 20, -90, 1),
		};
		foreach ( var (spec, x, y, facing) in layout )
		{
			var fish = new Fish( this, spec, new Vector2( x, y ), facing, _rng );
			fish.EndCombo = OnComboEnded;
			_fish.Add( fish );
		}
	}

	void Refill()
	{
		foreach ( var f in _fish ) f.Destroy();
		_fish.Clear();
		Fluid.Reset();
		SpawnFish();
	}

	Vector2 MouseWorld()
	{
		var w = _camera.ScreenToWorld( Mouse.Position );
		return new Vector2( w.x, w.y );
	}

	protected override void OnFixedUpdate()
	{
		if ( Fluid is null ) return;
		var dt = Time.Delta;

		var m = MouseWorld();
		var inWater = Fluid.InWater( m ) && m.y > Tank.GravelTop;
		var held = Input.Down( "Attack1" );
		_fistVel = Vector2.Zero;
		if ( _hasMousePrev )
		{
			var v = (m - _mousePrev) / dt;
			var jump = (m - _mousePrev).Length > 400; // cursor re-entered the window: not a swipe
			const float cap = 2600f;
			if ( v.Length > cap ) v = v.Normal * cap;
			if ( !jump )
			{
				_fistVel = held ? v * 1.25f : v; // a clenched fist hits harder
				if ( inWater )
					Fluid.DragTo( m, v, held ? 105f : 70f, held ? 0.55f : 0.25f );
			}
		}

		// direct hits, in the water and in the air
		foreach ( var f in _fish )
		{
			var hit = f.TryHit( m, FistRadius * (held ? 1.15f : 1f), _fistVel, Fluid );
			if ( hit > 0 )
			{
				_shake = MathF.Max( _shake, hit * 10f );
				_cursor.Punch();
				if ( f.Combo >= 2 ) ShowCombo( f );
			}
		}
		if ( _punchQueued )
		{
			if ( inWater ) Fluid.Radial( m, 900f, 110f );
			_punchQueued = false;
		}
		_mousePrev = m;
		_hasMousePrev = true;

		foreach ( var f in _fish )
			f.Tick( dt, Fluid );
		Fluid.Step( dt );
		Plants.Step( dt, Fluid );
	}

	protected override void OnUpdate()
	{
		if ( Fluid is null ) return;

		if ( Input.Pressed( "Reload" ) )
			Refill();
		if ( Input.Pressed( "Attack2" ) )
		{
			_punchQueued = true;
			_cursor.Punch();
		}

		// screen shake on big hits
		_shake = MathF.Max( 0, _shake - Time.Delta * 40f );
		var jitter = _shake > 0 ? new Vector2( (float)(_rng.NextDouble() - 0.5), (float)(_rng.NextDouble() - 0.5) ) * _shake : Vector2.Zero;
		_camera.WorldPosition = new Vector3( CameraCenter.x + jitter.x, CameraCenter.y + jitter.y, 1000 );

		_renderer.Build( this );
		DrawCombo();
		_cursor.Draw( _camera.Hud, Mouse.Position, Input.Down( "Attack1" ), Time.Delta );
	}

	void ShowCombo( Fish f )
	{
		_comboText = f.ComboBreaks > 0 ? $"AIR x{f.Combo}  +{f.ComboBreaks} TORN" : $"AIR x{f.Combo}";
		_comboShow = 1.4f;
		_comboAt = f.LastHitPoint;
	}

	void OnComboEnded( Fish f )
	{
		if ( f.Combo >= 2 )
		{
			_bestCombo = Math.Max( _bestCombo, f.Combo );
			_comboText = f.ComboBreaks > 0 ? $"{f.Combo} HIT COMBO  +{f.ComboBreaks} TORN" : $"{f.Combo} HIT COMBO";
			_comboShow = 2f;
			_comboAt = f.LastHitPoint;
		}
		f.ResetCombo();
	}

	void DrawCombo()
	{
		var hud = _camera.Hud;
		if ( _bestCombo > 0 )
			hud.DrawText( $"best x{_bestCombo}", 18, new Color( 1, 1, 1, 0.55f ), new Vector2( 24, 20 ) );
		if ( _comboShow <= 0 || _comboText is null ) return;
		_comboShow -= Time.Delta;
		var a = Math.Clamp( _comboShow, 0f, 1f );
		var screen = _camera.PointToScreenPixels( new Vector3( _comboAt.x, _comboAt.y, 0 ) );
		var pos = screen + new Vector2( 0, -60 - (1.4f - _comboShow) * 30f );
		hud.DrawText( _comboText, 34, new Color( 0, 0, 0, a * 0.6f ), pos + new Vector2( 2, 2 ), TextFlag.Center );
		hud.DrawText( _comboText, 34, new Color( 1f, 0.85f, 0.3f, a ), pos, TextFlag.Center );
	}
}
