namespace FishFlop;

/// <summary>
/// The whole game: a side-view tank. Move the fist through the water to push it,
/// hold left mouse to shove hard, right mouse punches a shockwave, R refills.
/// Needs the scene's physics mode set to 2D (tank.scene does this).
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
		go.WorldPosition = new Vector3( 0, 0, 1000 );
		go.WorldRotation = Rotation.LookAt( Vector3.Down, new Vector3( 0, 1, 0 ) ); // look into the tank, +Y up
		_camera = go.Components.Create<CameraComponent>();
		_camera.Orthographic = true;
		_camera.OrthographicHeight = 1100;
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
		Box( "Lid", new Vector2( 0, Tank.Lid + w * 0.5f ), new Vector2( width + 2 * w, w ) );
		Box( "Left glass", new Vector2( Tank.Left - w * 0.5f, 0 ), new Vector2( w, Tank.Lid - Tank.Bottom + 2 * w ) );
		Box( "Right glass", new Vector2( Tank.Right + w * 0.5f, 0 ), new Vector2( w, Tank.Lid - Tank.Bottom + 2 * w ) );

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
			(FishSpec.Goldie, -480, 150, 1),
			(FishSpec.Goldie, 150, 60, -1),
			(FishSpec.Goldie, -100, -250, 1),
			(FishSpec.Mackerel, -250, 270, 1),
			(FishSpec.Mackerel, 420, 240, -1),
			(FishSpec.Tang, -560, -200, 1),
			(FishSpec.Tang, 560, -60, -1),
			(FishSpec.Tang, 0, 140, 1),
		};
		foreach ( var (spec, x, y, facing) in layout )
			_fish.Add( new Fish( this, spec, new Vector2( x, y ), facing, _rng ) );
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
		var inWater = m.x > Tank.Left && m.x < Tank.Right && m.y > Tank.GravelTop && m.y < Fluid.SurfaceAt( m.x );
		if ( _hasMousePrev && inWater )
		{
			var v = (m - _mousePrev) / dt;
			var jump = (m - _mousePrev).Length > 400; // cursor re-entered the window: not a swipe
			const float cap = 2600f;
			if ( v.Length > cap ) v = v.Normal * cap;
			var held = Input.Down( "Attack1" );
			if ( !jump )
				Fluid.DragTo( m, v, held ? 105f : 70f, held ? 0.55f : 0.25f );
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

		_renderer.Build( this );
		_cursor.Draw( _camera.Hud, Mouse.Position, Input.Down( "Attack1" ), Time.Delta );
	}
}
