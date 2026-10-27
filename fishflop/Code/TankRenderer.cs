namespace FishFlop;

/// <summary>
/// Builds the whole tank as vertex-coloured triangles every frame and draws it
/// back to front in one pass (the shader ignores depth). Order:
/// room, cabinet, water body, plants, rock, gravel, fish, water veil, surface, glass, frame.
/// </summary>
public sealed class TankRenderer
{
	const int ChunkVerts = 24000;

	readonly Material _material;
	readonly object _lock = new();
	// three reused frames: one being built, one published, one possibly still being drawn
	readonly List<List<Vertex>>[] _frames = { new(), new(), new() };
	int _buildIndex;
	List<List<Vertex>> _building;
	List<List<Vertex>> _ready = new();
	List<Vertex> _cur;
	int _chunk;

	readonly List<(Vector2 c, float rx, float ry, Color32 col)> _pebbles = new();

	public TankRenderer( Random rng )
	{
		_material = Material.FromShader( "shaders/fishflop_vcolor.shader" );
		if ( _material is null )
		{
			// safety net: the engine's stock vertex colour material (lit, but still shows the game)
			Log.Warning( "fishflop_vcolor.shader failed to load, falling back to materials/default/vertex_color.vmat" );
			_material = Material.Load( "materials/default/vertex_color.vmat" );
		}

		// gravel: every pebble lies fully below the collision top, so nothing can sink into it visually
		for ( int layer = 0; layer < 4; layer++ )
		{
			for ( float x = Tank.Left + 4; x < Tank.Right; x += 9f + (float)rng.NextDouble() * 10f )
			{
				var ry = 4f + (float)rng.NextDouble() * 5f;
				var rx = ry * (1.1f + (float)rng.NextDouble() * 0.6f);
				var top = Tank.GravelTop - layer * 12f - (float)rng.NextDouble() * 4f;
				var c = new Vector2( x, top - ry );
				var shade = (byte)(105 + rng.Next( 70 ) - layer * 10);
				var col = new Color32( shade, (byte)(shade * 0.88f), (byte)(shade * 0.72f) );
				_pebbles.Add( (c, rx, ry, col) );
			}
		}
	}

	public void Render( SceneObject _ )
	{
		List<List<Vertex>> draw;
		lock ( _lock ) draw = _ready;
		foreach ( var chunk in draw )
			if ( chunk.Count > 0 )
				Graphics.Draw( chunk, chunk.Count, _material );
	}

	// ------------------------------------------------------------------ primitives

	void Begin()
	{
		_buildIndex = (_buildIndex + 1) % _frames.Length;
		_building = _frames[_buildIndex];
		foreach ( var list in _building ) list.Clear();
		_chunk = 0;
		if ( _building.Count == 0 ) _building.Add( new List<Vertex>( ChunkVerts ) );
		_cur = _building[0];
	}

	void End()
	{
		lock ( _lock ) _ready = _building;
	}

	void NextChunk()
	{
		_chunk++;
		if ( _chunk >= _building.Count ) _building.Add( new List<Vertex>( ChunkVerts ) );
		_cur = _building[_chunk];
	}

	void Tri( Vector2 a, Vector2 b, Vector2 c, Color32 ca, Color32 cb, Color32 cc )
	{
		if ( _cur.Count + 3 > ChunkVerts )
			NextChunk();
		_cur.Add( new Vertex( new Vector3( a.x, a.y, 0 ), ca ) );
		_cur.Add( new Vertex( new Vector3( b.x, b.y, 0 ), cb ) );
		_cur.Add( new Vertex( new Vector3( c.x, c.y, 0 ), cc ) );
	}

	void Tri( Vector2 a, Vector2 b, Vector2 c, Color32 col ) => Tri( a, b, c, col, col, col );

	void Quad( Vector2 a, Vector2 b, Vector2 c, Vector2 d, Color32 ca, Color32 cb, Color32 cc, Color32 cd )
	{
		Tri( a, b, c, ca, cb, cc );
		Tri( a, c, d, ca, cc, cd );
	}

	void Rect( float x0, float y0, float x1, float y1, Color32 bottom, Color32 top )
	{
		Quad( new( x0, y0 ), new( x1, y0 ), new( x1, y1 ), new( x0, y1 ), bottom, bottom, top, top );
	}

	void Fan( Vector2 center, IReadOnlyList<Vector2> ring, Color32 cc, Color32 cr, bool closed = true )
	{
		var n = ring.Count;
		var last = closed ? n : n - 1;
		for ( int i = 0; i < last; i++ )
			Tri( center, ring[i], ring[(i + 1) % n], cc, cr, cr );
	}

	void Ellipse( Vector2 c, float rx, float ry, Color32 inner, Color32 outer, int seg = 12 )
	{
		var ring = new Vector2[seg];
		for ( int i = 0; i < seg; i++ )
		{
			var a = i * MathF.PI * 2 / seg;
			ring[i] = c + new Vector2( MathF.Cos( a ) * rx, MathF.Sin( a ) * ry );
		}
		Fan( c, ring, inner, outer );
	}

	void Line( IReadOnlyList<Vector2> pts, float width, Color32 col, bool closed = false )
	{
		var n = pts.Count;
		var segs = closed ? n : n - 1;
		for ( int i = 0; i < segs; i++ )
		{
			var a = pts[i];
			var b = pts[(i + 1) % n];
			var d = b - a;
			var len = d.Length;
			if ( len < 1e-3f ) continue;
			var nrm = new Vector2( -d.y, d.x ) / len * (width * 0.5f);
			Quad( a - nrm, b - nrm, b + nrm, a + nrm, col, col, col, col );
		}
	}

	static Color32 Lerp( Color32 a, Color32 b, float t, byte? alpha = null )
	{
		t = Math.Clamp( t, 0f, 1f );
		return new Color32(
			(byte)(a.r + (b.r - a.r) * t),
			(byte)(a.g + (b.g - a.g) * t),
			(byte)(a.b + (b.b - a.b) * t),
			alpha ?? (byte)(a.a + (b.a - a.a) * t) );
	}

	static Color32 A( Color32 c, byte alpha ) => new( c.r, c.g, c.b, alpha );

	// ------------------------------------------------------------------ frame

	public void Build( TankGame game )
	{
		Begin();
		DrawRoom();
		DrawWaterBody( game.Fluid );
		DrawPlants( game.Plants );
		DrawRock();
		DrawGravel( game.Plants );
		foreach ( var f in game.AllFish )
			DrawFish( f );
		DrawWaterVeil( game.Fluid );
		DrawSurfaceAndGlass( game.Fluid );
		End();
	}

	void DrawRoom()
	{
		// wall with a skirting board, wooden floor, and the low stand the tank sits on
		var hw = Tank.RoomHalfWidth + 40;
		Rect( -hw, Tank.Floor, hw, 760, new Color32( 44, 40, 46 ), new Color32( 62, 56, 62 ) );
		Rect( -hw, Tank.Floor, hw, Tank.Floor + 26, new Color32( 70, 60, 54 ), new Color32( 84, 72, 64 ) );
		Rect( -hw, -700, hw, Tank.Floor, new Color32( 70, 46, 28 ), new Color32( 104, 70, 42 ) );
		// ceiling with a cornice along the top of the screen: fish knocked up high bounce off it
		Rect( -hw, Tank.Ceiling, hw, 800, new Color32( 74, 68, 72 ), new Color32( 86, 80, 84 ) );
		Rect( -hw, Tank.Ceiling - 10, hw, Tank.Ceiling, new Color32( 96, 88, 90 ), new Color32( 120, 112, 114 ) );
		for ( float x = -hw; x < hw; x += 170 )
			Line( new[] { new Vector2( x, -700 ), new Vector2( x + 20, Tank.Floor ) }, 2, new Color32( 58, 38, 22 ) );

		var sw = Tank.StandHalfWidth;
		Rect( -sw, Tank.Floor, sw, Tank.StandTop, new Color32( 58, 38, 24 ), new Color32( 92, 62, 38 ) );
		Rect( -sw, Tank.StandTop - 12, sw, Tank.StandTop, new Color32( 120, 84, 52 ), new Color32( 140, 100, 62 ) );
		Line( new[] { new Vector2( 0, Tank.Floor ), new Vector2( 0, Tank.StandTop - 16 ) }, 3, new Color32( 40, 26, 16 ) );

		// back glass of the tank: what you see through the air part, a cooler tint of the wall
		Rect( Tank.Left, Tank.Surface - 30, Tank.Right, Tank.Rim, new Color32( 58, 64, 72 ), new Color32( 66, 70, 78 ) );
	}

	Color32 WaterColor( Fluid fl, int i, int j )
	{
		// average the (up to) four cells that touch this grid corner
		float tr = 0, bl = 0, sp = 0;
		int cnt = 0;
		for ( int dj = -1; dj <= 0; dj++ )
			for ( int di = -1; di <= 0; di++ )
			{
				var ci = Math.Clamp( i + di, 0, Fluid.NX - 1 );
				var cj = Math.Clamp( j + dj, 0, Fluid.NY - 1 );
				var k = Fluid.Idx( ci, cj );
				tr += fl.Tracer[k];
				bl += fl.Blood[k];
				sp += MathF.Sqrt( fl.U[k] * fl.U[k] + fl.V[k] * fl.V[k] );
				cnt++;
			}
		tr /= cnt; bl /= cnt; sp /= cnt;

		var t = (float)j / Fluid.NY;
		float r = 18 + (60 - 18) * t, g = 55 + (140 - 55) * t, b = 80 + (170 - 80) * t;
		var tex = (tr - 0.5f) * 50f + MathF.Min( sp / 400f, 1f ) * 35f;
		r += tex; g += tex; b += tex;
		var c = 1 - MathF.Exp( -bl * 1.6f );
		r = r * (1 - c) + 120 * c;
		g = g * (1 - c) + 8 * c;
		b = b * (1 - c) + 12 * c;
		return new Color32( (byte)Math.Clamp( r, 0, 255 ), (byte)Math.Clamp( g, 0, 255 ), (byte)Math.Clamp( b, 0, 255 ) );
	}

	Vector2 WaterCorner( Fluid fl, int i, int j )
	{
		var x = Tank.Left + i * Fluid.DX;
		var y = j == Fluid.NY ? Tank.Surface + fl.Surf[i] : Tank.Bottom + j * Fluid.DY;
		return new Vector2( x, y );
	}

	void DrawWaterBody( Fluid fl )
	{
		var cols = new Color32[(Fluid.NX + 1) * (Fluid.NY + 1)];
		for ( int j = 0; j <= Fluid.NY; j++ )
			for ( int i = 0; i <= Fluid.NX; i++ )
				cols[j * (Fluid.NX + 1) + i] = WaterColor( fl, i, j );

		var jStart = (int)((Tank.GravelTop - Tank.Bottom) / Fluid.DY) - 1; // under the gravel is never seen
		for ( int j = Math.Max( 0, jStart ); j < Fluid.NY; j++ )
			for ( int i = 0; i < Fluid.NX; i++ )
			{
				int k00 = j * (Fluid.NX + 1) + i, k10 = k00 + 1, k01 = k00 + Fluid.NX + 1, k11 = k01 + 1;
				Quad( WaterCorner( fl, i, j ), WaterCorner( fl, i + 1, j ), WaterCorner( fl, i + 1, j + 1 ), WaterCorner( fl, i, j + 1 ),
					cols[k00], cols[k10], cols[k11], cols[k01] );
			}
	}

	void DrawWaterVeil( Fluid fl )
	{
		// a thin layer of the same water in front of everything: fish sit IN it, and blood clouds pass over them
		const int step = 2;
		for ( int j = 0; j < Fluid.NY; j += step )
			for ( int i = 0; i < Fluid.NX; i += step )
			{
				var i1 = Math.Min( i + step, Fluid.NX );
				var j1 = Math.Min( j + step, Fluid.NY );
				Quad( WaterCorner( fl, i, j ), WaterCorner( fl, i1, j ), WaterCorner( fl, i1, j1 ), WaterCorner( fl, i, j1 ),
					Veil( fl, i, j ), Veil( fl, i1, j ), Veil( fl, i1, j1 ), Veil( fl, i, j1 ) );
			}
	}

	Color32 Veil( Fluid fl, int i, int j )
	{
		var k = Fluid.Idx( Math.Clamp( i, 0, Fluid.NX - 1 ), Math.Clamp( j, 0, Fluid.NY - 1 ) );
		var c = 1 - MathF.Exp( -fl.Blood[k] * 1.6f );
		var water = new Color32( 40, 110, 140 );
		var col = Lerp( water, new Color32( 120, 8, 12 ), c );
		return A( col, (byte)(18 + c * 150) );
	}

	void DrawSurfaceAndGlass( Fluid fl )
	{
		// the air gap above the water, the surface line, then glass glare
		var top = new List<Vector2>();
		for ( int i = 0; i <= Fluid.NX; i++ )
			top.Add( WaterCorner( fl, i, Fluid.NY ) );
		for ( int i = 0; i < Fluid.NX; i++ )
			Quad( top[i], top[i + 1], new Vector2( top[i + 1].x, Tank.Rim ), new Vector2( top[i].x, Tank.Rim ),
				new Color32( 200, 225, 235, 18 ), new Color32( 200, 225, 235, 18 ), new Color32( 200, 225, 235, 8 ), new Color32( 200, 225, 235, 8 ) );
		Line( top, 4f, new Color32( 190, 230, 240, 170 ) );
		var under = top.Select( p => p - new Vector2( 0, 7 ) ).ToList();
		Line( under, 6f, new Color32( 120, 190, 210, 50 ) );

		// glare on the front glass
		Quad( new( -520, Tank.Bottom ), new( -380, Tank.Bottom ), new( -160, Tank.Rim ), new( -300, Tank.Rim ),
			new Color32( 255, 255, 255, 0 ), new Color32( 255, 255, 255, 0 ), new Color32( 255, 255, 255, 18 ), new Color32( 255, 255, 255, 18 ) );
		Quad( new( -330, Tank.Bottom ), new( -300, Tank.Bottom ), new( -80, Tank.Rim ), new( -110, Tank.Rim ),
			new Color32( 255, 255, 255, 0 ), new Color32( 255, 255, 255, 0 ), new Color32( 255, 255, 255, 26 ), new Color32( 255, 255, 255, 26 ) );

		// frame: base rail, glass side walls up to an open rim with a thin top trim
		var f = Tank.FrameThickness;
		var w = Tank.WallThickness;
		var dark = new Color32( 18, 18, 20 );
		var edge = new Color32( 46, 46, 50 );
		var glass = new Color32( 150, 190, 205, 70 );
		Rect( Tank.Left - f, Tank.Bottom - f, Tank.Right + f, Tank.Bottom, dark, edge );
		Rect( Tank.Left - w, Tank.Bottom, Tank.Left, Tank.Rim, glass, glass );
		Rect( Tank.Right, Tank.Bottom, Tank.Right + w, Tank.Rim, glass, glass );
		Rect( Tank.Left - w - 2, Tank.Rim - 10, Tank.Left + 2, Tank.Rim, edge, dark );
		Rect( Tank.Right - 2, Tank.Rim - 10, Tank.Right + w + 2, Tank.Rim, edge, dark );
		Rect( Tank.Left - f, Tank.Rim - 4, Tank.Right + f, Tank.Rim, new Color32( 200, 225, 235, 60 ), new Color32( 200, 225, 235, 60 ) );
	}

	// ------------------------------------------------------------------ flora, rock, gravel

	void DrawPlants( Plants plants )
	{
		foreach ( var s in plants.Strands )
		{
			var n = s.P.Length;
			var left = new Vector2[n];
			var right = new Vector2[n];
			for ( int i = 0; i < n; i++ )
			{
				var t = (float)i / (n - 1);
				var d = i < n - 1 ? s.P[i + 1] - s.P[i] : s.P[i] - s.P[i - 1];
				var nrm = new Vector2( -d.y, d.x ).Normal;
				var w = s.HalfWidth( t );
				if ( i == n - 1 ) w *= 0.2f;
				left[i] = s.P[i] + nrm * w;
				right[i] = s.P[i] - nrm * w;
			}
			for ( int i = 0; i < n - 1; i++ )
			{
				var t0 = (float)i / (n - 1);
				var t1 = (float)(i + 1) / (n - 1);
				var c0 = Lerp( s.Base, s.Tip, t0 );
				var c1 = Lerp( s.Base, s.Tip, t1 );
				var e0 = Lerp( c0, new Color32( 0, 0, 0 ), 0.25f );
				var e1 = Lerp( c1, new Color32( 0, 0, 0 ), 0.25f );
				Quad( left[i], left[i + 1], s.P[i + 1], s.P[i], e0, e1, c1, c0 );
				Quad( s.P[i], s.P[i + 1], right[i + 1], right[i], c0, c1, e1, e0 );
			}
			if ( s.Broad )
				Line( s.P, 1.6f, s.Vein );
		}
	}

	void DrawRock()
	{
		var stone = new Color32( 104, 100, 94 );
		var shade = new Color32( 70, 66, 62 );
		foreach ( var piece in Tank.ArchPieces )
		{
			var pts = piece.Select( Tank.ArchPoint ).ToArray();
			var c = Vector2.Zero;
			foreach ( var p in pts ) c += p;
			c /= pts.Length;
			var ring = pts.ToList();
			Fan( c, ring, stone, shade );
		}
		Line( Tank.ArchOutline.Select( Tank.ArchPoint ).ToList(), 3f, new Color32( 40, 38, 36 ), true );
		Line( Tank.ArchHole.Select( Tank.ArchPoint ).ToList(), 3f, new Color32( 40, 38, 36 ), false );
		// a few lichen spots
		foreach ( var (x, y, r) in new[] { (-80f, 120f, 9f), (-30f, 138f, 6f), (70f, 128f, 8f), (95f, 60f, 6f) } )
			Ellipse( Tank.ArchPoint( new Vector2( x, y ) ), r, r * 0.7f, new Color32( 110, 140, 70 ), new Color32( 80, 110, 55 ), 8 );
	}

	void DrawGravel( Plants plants )
	{
		Rect( Tank.Left, Tank.Bottom, Tank.Right, Tank.GravelTop - 2, new Color32( 70, 58, 44 ), new Color32( 112, 96, 74 ) );
		foreach ( var (c, rx, ry, col) in _pebbles )
			Ellipse( c, rx, ry, col, Lerp( col, new Color32( 30, 24, 18 ), 0.45f ), 10 );
		// little mounds where plant crowns go into the gravel
		foreach ( var c in plants.Crowns )
			Ellipse( new Vector2( c.x, Tank.GravelTop - 8 ), 26, 8, new Color32( 96, 82, 62 ), new Color32( 72, 60, 46 ), 14 );
	}

	// ------------------------------------------------------------------ fish

	Vector2 SkinPoint( Fish f, int a, int b, float s, float ly, float extendX = 0 )
	{
		const float bw = 0.05f;
		var spec = f.Spec;
		int k = a;
		while ( k < b && s > f.Ss[k + 1] ) k++;
		var local = f.M( new Vector2( spec.X( s ) + extendX, ly ) );
		var p = f.Parts[k].ToWorld( local );
		// blend across intact joints inside this piece: one smooth skin, no gaps at the hinges
		for ( int j = a + 1; j <= b; j++ )
		{
			var d = s - f.Ss[j];
			if ( MathF.Abs( d ) >= bw ) continue;
			var w = Tank.Smoothstep( -bw, bw, d );
			var pa = f.Parts[j - 1].ToWorld( local );
			var pb = f.Parts[j].ToWorld( local );
			p = pa * (1 - w) + pb * w;
		}
		return p;
	}

	List<(int a, int b)> Pieces( Fish f )
	{
		var n = f.Spec.Segments;
		var list = new List<(int, int)>();
		int start = 0;
		for ( int k = 0; k < n - 1; k++ )
		{
			if ( f.Joints[k].Broken )
			{
				list.Add( (start, k) );
				start = k + 1;
			}
		}
		list.Add( (start, n - 1) );
		return list;
	}

	static readonly Color32 WaterTint = new( 40, 110, 140 );

	Color32 Sub( Color32 c ) => Lerp( c, WaterTint, 0.12f ); // seen through water

	void DrawFish( Fish f )
	{
		var spec = f.Spec;
		var fin = Sub( spec.FinColor );
		var finDark = Lerp( fin, new Color32( 20, 30, 40 ), 0.35f );
		var finTip = Lerp( fin, new Color32( 255, 255, 255 ), 0.15f, 200 );

		// fins that sit behind the body
		DrawFin( f, f.TailFin, f.TailOutline, new Vector2( spec.X( 1f ) + 0.01f * spec.Length, 0 ), A( fin, 235 ), finTip, finDark );
		var d0 = f.DorsalOutline;
		DrawFin( f, f.Dorsal, d0, (d0[0] + d0[3]) * 0.5f, A( fin, 235 ), finTip, finDark );

		var outline = Sub( Lerp( spec.Back, new Color32( 0, 0, 0 ), 0.6f ) );
		var n = spec.Segments;
		foreach ( var (a, b) in Pieces( f ) )
		{
			var s0 = f.Ss[a];
			var s1 = f.Ss[b + 1];
			var steps = Math.Max( 8, (int)((s1 - s0) * 48) );

			// dark outline pass: the same skin, 2.2 units fatter
			DrawSkin( f, a, b, s0, s1, steps, 2.2f, outline, outline, outline, outline );
			var back = Sub( spec.Back );
			var belly = Sub( spec.Belly );
			DrawSkin( f, a, b, s0, s1, steps, 0f, Lerp( back, new Color32( 0, 0, 0 ), 0.15f ), back, Lerp( back, belly, 0.7f ), Lerp( belly, new Color32( 0, 0, 0 ), 0.08f ) );

			// open wounds where joints have torn
			if ( s0 > 0 ) DrawWound( f, a, s0, +1, f.Joints[a - 1].Seed );
			var tailGone = f.Joints[n - 1].Broken;
			if ( s1 < 1 || (b == n - 1 && tailGone) ) DrawWound( f, b, s1, -1, f.Joints[b].Seed );
		}

		DrawStrands( f );
		DrawScraps( f );

		var pec = f.PectoralOutline;
		DrawFin( f, f.Pectoral, pec, (pec[0] + pec[^1]) * 0.5f, A( Lerp( fin, new Color32( 255, 255, 255 ), 0.25f ), 200 ), A( finTip, 150 ), finDark );

		// eye, gill, mouth on the head
		var head = f.Head;
		var hs = spec.HeadFrac;
		var eyeL = new Vector2( spec.X( hs * 0.32f ), spec.H( hs * 0.32f ).top * 0.25f );
		var r = MathF.Max( 3f, spec.HalfHeight * 0.16f );
		var eye = head.ToWorld( f.M( eyeL ) );
		Ellipse( eye, r + 1.2f, r + 1.2f, outline, outline );
		Ellipse( eye, r, r, new Color32( 245, 245, 240 ), new Color32( 215, 215, 210 ) );
		var dead = !f.Alive && f.Dying <= 0;
		Ellipse( eye + new Vector2( 0.6f * f.Facing, 0 ), r * 0.55f, r * 0.55f, dead ? new Color32( 150, 150, 160 ) : new Color32( 10, 10, 10 ), dead ? new Color32( 120, 120, 130 ) : new Color32( 10, 10, 10 ) );
		if ( !dead ) Ellipse( eye + new Vector2( 1.2f * f.Facing, r * 0.3f ), r * 0.18f, r * 0.18f, new Color32( 255, 255, 255 ), new Color32( 255, 255, 255 ), 6 );

		var gill = new List<Vector2>();
		for ( int i = 0; i <= 6; i++ )
		{
			var t = i / 6f;
			var gs = hs * 0.8f;
			gill.Add( head.ToWorld( f.M( new Vector2( spec.X( gs ) + 4 * MathF.Sin( t * MathF.PI ), spec.H( gs ).top * (0.7f - 1.4f * t) ) ) ) );
		}
		Line( gill, 1.8f, outline );
		var mouth = new List<Vector2>
		{
			head.ToWorld( f.M( new Vector2( spec.X( 0.015f ), -spec.H( 0.04f ).bottom * 0.15f ) ) ),
			head.ToWorld( f.M( new Vector2( spec.X( 0.06f ), -spec.H( 0.06f ).bottom * 0.25f ) ) ),
		};
		Line( mouth, 1.6f, outline );
	}

	void DrawSkin( Fish f, int a, int b, float s0, float s1, int steps, float grow, Color32 cTop, Color32 cUpper, Color32 cMid, Color32 cBottom )
	{
		var spec = f.Spec;
		Vector2 pt0 = default, pu0 = default, pm0 = default, pb0 = default;
		Color32 ctop0 = default, cup0 = default;
		for ( int i = 0; i <= steps; i++ )
		{
			var s = s0 + (s1 - s0) * i / steps;
			var (ht, hb) = spec.H( s );
			var ext = i == 0 && s0 <= 0 ? grow : 0f; // fatten the snout tip too
			var pt = SkinPoint( f, a, b, s, ht + grow, ext );
			var pu = SkinPoint( f, a, b, s, ht * 0.45f, ext );
			var pm = SkinPoint( f, a, b, s, 0, ext );
			var pb = SkinPoint( f, a, b, s, -(hb + grow), ext );

			var ctop = cTop;
			var cup = cUpper;
			if ( grow <= 0 && spec.Stripe is Color32 stripe )
			{
				// mackerel tiger bars on the upper half, following the body as it bends
				var band = MathF.Sin( s * 46f );
				if ( band > 0.35f )
				{
					var st = Sub( stripe );
					ctop = st;
					cup = Lerp( st, cUpper, 0.35f );
				}
			}

			if ( i > 0 )
			{
				Quad( pt0, pt, pu, pu0, ctop0, ctop, cup, cup0 );
				Quad( pu0, pu, pm, pm0, cup0, cup, cMid, cMid );
				Quad( pm0, pm, pb, pb0, cMid, cMid, cBottom, cBottom );
			}
			pt0 = pt; pu0 = pu; pm0 = pm; pb0 = pb;
			ctop0 = ctop; cup0 = cup;
		}
	}

	static float Hash( int seed, int i )
	{
		unchecked
		{
			var x = seed * 73856093 ^ i * 19349663;
			x ^= x >> 13;
			x *= 1274126177;
			return (x & 0xFFFF) / 65535f;
		}
	}

	static readonly Color32 Meat = new( 175, 40, 45 );
	static readonly Color32 MeatDark = new( 95, 8, 14 );
	static readonly Color32 Bone = new( 238, 230, 212 );

	/// <summary>
	/// A torn end: ragged, skewed edge of flesh with a flap of skin hanging off. The front half
	/// keeps the spine bone sticking out; the back half shows the socket it was ripped from.
	/// </summary>
	void DrawWound( Fish f, int seg, float s, int sign, int seed )
	{
		var spec = f.Spec;
		var part = f.Parts[seg];
		var (ht, hb) = spec.H( s );
		var cx = spec.X( s );
		var h = ht + hb;
		var bulge = spec.Length * 0.04f * sign;
		var skew = (Hash( seed, 99 ) - 0.5f) * 1.6f;
		Vector2 W( float x, float y ) => part.ToWorld( f.M( new Vector2( x, y ) ) );

		const int pts = 13;
		var ring = new List<Vector2>();
		for ( int i = 0; i < pts; i++ )
		{
			var t = i / (float)(pts - 1);
			var reach = 0.35f + 0.65f * MathF.Sin( MathF.PI * t );
			reach *= 0.55f + Hash( seed, i ) * 1.1f;  // ragged
			if ( i % 3 == 1 ) reach *= 0.25f;         // torn notches
			var x = cx + bulge * reach + bulge * skew * (t - 0.5f);
			ring.Add( W( x, ht - h * t ) );
		}
		var center = W( cx + bulge * 0.25f, (ht - hb) * 0.5f );
		Fan( center, ring, Meat, MeatDark, false );
		Line( ring, 1.4f, MeatDark );

		// a flap of torn skin hanging off the top edge, and a smaller one of belly skin
		var back = Sub( spec.Back );
		var belly = Sub( spec.Belly );
		var flapLen = 1.2f + Hash( seed, 50 ) * 0.8f;
		Tri( W( cx - bulge * 0.15f, ht ), W( cx + bulge * flapLen, ht - h * (0.1f + Hash( seed, 51 ) * 0.15f) ), W( cx + bulge * 0.25f, ht - h * 0.22f ),
			back, Lerp( back, MeatDark, 0.35f ), Lerp( back, MeatDark, 0.2f ) );
		Tri( W( cx - bulge * 0.1f, -hb ), W( cx + bulge * (0.8f + Hash( seed, 52 ) * 0.6f), -hb + h * 0.12f ), W( cx + bulge * 0.2f, -hb + h * 0.2f ),
			belly, Lerp( belly, MeatDark, 0.3f ), Lerp( belly, MeatDark, 0.15f ) );

		var mid = (ht - hb) * 0.5f;
		var boneW = MathF.Max( 2f, h * 0.1f );
		if ( sign < 0 )
		{
			// the front half keeps the spine: a bone sticking out, with a couple of rib stubs
			var tip = W( cx + bulge * 2.3f, mid + (Hash( seed, 60 ) - 0.5f) * h * 0.15f );
			var root = W( cx - bulge * 0.2f, mid );
			Line( new[] { root, tip }, boneW, Bone );
			Ellipse( tip, boneW * 0.8f, boneW * 0.8f, Bone, new Color32( 200, 190, 170 ), 8 );
			for ( int r = 0; r < 2; r++ )
			{
				var along = 0.5f + r * 0.6f;
				var from = W( cx + bulge * along, mid );
				var to = W( cx + bulge * (along + 0.4f), mid + (r == 0 ? 1 : -1) * h * 0.22f );
				Line( new[] { from, to }, boneW * 0.45f, Bone );
			}
		}
		else
		{
			// the back half: the socket the spine was pulled out of
			var socket = W( cx + bulge * 0.35f, mid );
			Ellipse( socket, boneW * 1.3f, boneW * 1.1f, new Color32( 50, 0, 6 ), MeatDark, 10 );
		}
	}

	/// <summary>For a moment after a tear, strands of flesh stretch between the halves and snap.</summary>
	void DrawStrands( Fish f )
	{
		var spec = f.Spec;
		foreach ( var j in f.Joints )
		{
			if ( !j.Broken || j.Kind == "fin" || j.TornAt < 0 ) continue;
			var age = f.Clock - j.TornAt;
			if ( age > 0.45f ) continue;
			var (ht, hb) = spec.H( j.S );
			var x = spec.X( j.S );
			for ( int k = 0; k < 3; k++ )
			{
				var oy = k == 0 ? ht * 0.5f : k == 1 ? 0 : -hb * 0.5f;
				var pa = j.A.ToWorld( f.M( new Vector2( x, oy ) ) );
				var pb = j.B.ToWorld( f.M( new Vector2( x, oy ) ) );
				var d = (pb - pa).Length;
				var snapAt = 60f + Hash( j.Seed, 70 + k ) * 70f;
				if ( d > snapAt ) continue; // this strand has snapped
				var width = 3.4f * (1 - age / 0.45f) * (1 - d / snapAt) + 0.6f;
				var sag = (pa + pb) * 0.5f + new Vector2( 0, -d * 0.18f );
				Line( new[] { pa, sag, pb }, width, k == 1 ? new Color32( 210, 190, 175 ) : Meat ); // middle strand is sinew
			}
		}
	}

	void DrawScraps( Fish f )
	{
		foreach ( var p in f.Parts )
		{
			if ( p.Kind != "scrap" || p.LocalPolys.Count == 0 ) continue;
			var local = p.LocalPolys[0];
			var ring = local.Select( p.ToWorld ).ToList();
			var c = p.ToWorld( Vector2.Zero );
			var skin = Sub( f.Spec.Back );
			var n = ring.Count;
			for ( int i = 0; i < n; i++ )
			{
				// edge points on the top side still carry skin; the rest is raw meat
				var ci = local[i].y > 0 ? skin : MeatDark;
				var cj = local[(i + 1) % n].y > 0 ? skin : MeatDark;
				Tri( c, ring[i], ring[(i + 1) % n], Meat, ci, cj );
			}
			Line( ring, 1.2f, Lerp( MeatDark, new Color32( 0, 0, 0 ), 0.3f ), true );
			Line( new[] { c + (ring[0] - c) * 0.6f, c + (ring[n / 2] - c) * 0.6f }, 1.1f, new Color32( 235, 205, 195 ) ); // a streak of fat
		}
	}

	void DrawFin( Fish f, FishPart part, Vector2[] outlineRest, Vector2 baseRest, Color32 baseCol, Color32 tipCol, Color32 rayCol )
	{
		var ring = outlineRest.Select( p => part.ToWorld( f.M( p ) ) ).ToList();
		var c = part.ToWorld( f.M( baseRest ) );
		Line( ring, 2.4f, rayCol, true );
		Fan( c, ring, baseCol, tipCol );
		// fin rays from the base out to the edge
		for ( int i = 1; i < ring.Count - 1; i++ )
			Line( new[] { c, c + (ring[i] - c) * 0.92f }, 1.1f, A( rayCol, 150 ) );
	}
}
