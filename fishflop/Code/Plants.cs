namespace FishFlop;

/// <summary>
/// A leaf or blade: a chain of points rooted below the gravel line, kept upright by
/// bending stiffness and a little buoyancy, swayed by the water. Plants sit behind
/// the fish (deeper in the tank) so they never collide with them.
/// </summary>
public sealed class PlantStrand
{
	public Vector2[] P;
	public Vector2[] Prev;
	public float SegLen;
	public float Width;        // max half width
	public float WidthPeak;    // where along the strand it is widest (0..1)
	public float Stiffness;
	public float RestAngle;    // radians from vertical, + leans left
	public Color32 Base, Tip, Vein;
	public bool Broad;         // sword leaf (has a midrib) vs ribbon grass

	public float HalfWidth( float t )
	{
		var w = Broad
			? MathF.Sin( MathF.PI * MathF.Min( 1f, MathF.Pow( t, 0.8f ) ) ) * (t < 0.18f ? t / 0.18f * 0.25f + 0.1f : 1f)
			: (1 - t * 0.85f);
		return Width * MathF.Max( w, 0.05f );
	}
}

public sealed class Plants
{
	public readonly List<PlantStrand> Strands = new();
	public readonly List<Vector2> Crowns = new(); // where each plant leaves the gravel, for the root mound

	public Plants( Random rng )
	{
		// ribbon grass clumps
		foreach ( var x in new[] { -700f, -610f, -40f, 560f, 690f } )
		{
			int blades = 5 + rng.Next( 4 );
			for ( int b = 0; b < blades; b++ )
			{
				var h = 300f + (float)rng.NextDouble() * 330f;
				var strand = Make( new Vector2( x + (float)(rng.NextDouble() - 0.5) * 30f, Tank.GravelTop - 14f ), h, 14,
					(float)(rng.NextDouble() - 0.5) * 0.35f, 5.5f + (float)rng.NextDouble() * 2.5f, 0.7f, false,
					new Color32( 40, 95, 45 ), new Color32( 110, 170, 70 ), new Color32( 30, 70, 35 ) );
				strand.Stiffness = 0.2f;
				Strands.Add( strand );
			}
			Crowns.Add( new Vector2( x, Tank.GravelTop ) );
		}

		// sword plants: rosettes of broad leaves on stalks
		foreach ( var x in new[] { -330f, 440f } )
		{
			int leaves = 7;
			for ( int b = 0; b < leaves; b++ )
			{
				var lean = (b - (leaves - 1) * 0.5f) * 0.2f + (float)(rng.NextDouble() - 0.5) * 0.08f;
				var h = 150f + (float)rng.NextDouble() * 90f - MathF.Abs( lean ) * 70f;
				var strand = Make( new Vector2( x + lean * 10f, Tank.GravelTop - 10f ), h, 9, lean, 26f, 0.62f, true,
					new Color32( 35, 110, 50 ), new Color32( 90, 175, 80 ), new Color32( 160, 210, 120 ) );
				strand.Stiffness = 0.22f;
				Strands.Add( strand );
			}
			Crowns.Add( new Vector2( x, Tank.GravelTop ) );
		}
	}

	static PlantStrand Make( Vector2 root, float height, int n, float lean, float width, float peak, bool broad, Color32 a, Color32 b, Color32 vein )
	{
		var s = new PlantStrand
		{
			P = new Vector2[n],
			Prev = new Vector2[n],
			SegLen = height / (n - 1),
			Width = width,
			WidthPeak = peak,
			RestAngle = lean,
			Broad = broad,
			Base = a,
			Tip = b,
			Vein = vein,
		};
		var dir = new Vector2( -MathF.Sin( lean ), MathF.Cos( lean ) );
		for ( int i = 0; i < n; i++ )
		{
			s.P[i] = root + dir * (s.SegLen * i);
			s.Prev[i] = s.P[i];
		}
		return s;
	}

	public void Step( float dt, Fluid fluid )
	{
		foreach ( var s in Strands )
		{
			var n = s.P.Length;
			// flow felt along the blade, smoothed so small eddies bend it, not kink it
			var flows = new Vector2[n];
			for ( int i = 0; i < n; i++ ) flows[i] = fluid.Velocity( s.P[i] );
			for ( int i = 2; i < n; i++ )
			{
				var p = s.P[i];
				var v = (p - s.Prev[i]) / dt;
				var flow = (flows[i - 1] + flows[i] * 2f + flows[Math.Min( i + 1, n - 1 )]) * 0.25f;
				// water drags the leaf, a little buoyancy keeps it standing
				var acc = (flow - v) * 3.2f + new Vector2( 0, 60f );
				s.Prev[i] = p;
				var np = p + v * dt * 0.985f + acc * dt * dt;
				np.y = MathF.Min( np.y, fluid.SurfaceAt( np.x ) - 6f ); // leaves stay under the surface
				s.P[i] = np;
			}

			for ( int it = 0; it < 6; it++ )
			{
				// second node keeps the rest direction: the stem leaves the gravel at its angle
				var dir0 = new Vector2( -MathF.Sin( s.RestAngle ), MathF.Cos( s.RestAngle ) );
				s.P[1] = s.P[0] + dir0 * s.SegLen;

				for ( int i = 1; i < n; i++ )
				{
					var d = s.P[i] - s.P[i - 1];
					var len = d.Length;
					if ( len < 1e-4f ) continue;
					var corr = d * ((len - s.SegLen) / len);
					if ( i == 1 ) continue;
					s.P[i] -= corr;
				}

				// bending: pull each node towards the straight continuation of the previous two
				for ( int i = 2; i < n; i++ )
				{
					var straight = s.P[i - 1] + (s.P[i - 1] - s.P[i - 2]);
					s.P[i] += (straight - s.P[i]) * s.Stiffness;
				}

				// keep everything inside the tank and above the gravel
				for ( int i = 2; i < n; i++ )
				{
					s.P[i].x = Math.Clamp( s.P[i].x, Tank.Left + 6, Tank.Right - 6 );
					s.P[i].y = MathF.Max( s.P[i].y, Tank.GravelTop + 4 );
				}
			}
		}
	}
}
