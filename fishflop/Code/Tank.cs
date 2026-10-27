namespace FishFlop;

/// <summary>
/// Tank dimensions, shared by physics, fluid and rendering. World space is the 2D
/// physics plane: X right, Y up, in s&box units.
/// </summary>
public static class Tank
{
	public const float Left = -800f;
	public const float Right = 800f;
	public const float Bottom = -450f;
	public const float Lid = 450f;
	public const float GravelTop = -400f;
	public const float Surface = 380f;
	public const float Gravity = 850f;

	public const float WallThickness = 30f;
	public const float FrameThickness = 26f;

	/// <summary>Rock arch, base centre on the gravel. Five convex pieces leave a real hole.</summary>
	public static readonly Vector2 ArchBase = new( 270f, GravelTop - 6f );

	public static readonly Vector2[][] ArchPieces =
	{
		new Vector2[] { new( -120, 0 ), new( -62, 0 ), new( -58, 92 ), new( -112, 100 ) },
		new Vector2[] { new( 62, 0 ), new( 120, 0 ), new( 112, 100 ), new( 58, 92 ) },
		new Vector2[] { new( -112, 100 ), new( -58, 92 ), new( -30, 118 ), new( -40, 150 ), new( -96, 150 ) },
		new Vector2[] { new( -30, 118 ), new( 30, 118 ), new( 40, 150 ), new( -40, 150 ) },
		new Vector2[] { new( 30, 118 ), new( 58, 92 ), new( 112, 100 ), new( 96, 150 ), new( 40, 150 ) },
	};

	public static readonly Vector2[] ArchOutline =
	{
		new( -120, 0 ), new( 120, 0 ), new( 112, 100 ), new( 96, 150 ), new( -96, 150 ), new( -112, 100 ),
	};

	public static readonly Vector2[] ArchHole =
	{
		new( -62, 0 ), new( 62, 0 ), new( 58, 92 ), new( 30, 118 ), new( -30, 118 ), new( -58, 92 ),
	};

	public static Vector2 ArchPoint( Vector2 local ) => ArchBase + local;

	public static bool PointInPolygon( Vector2 p, Vector2[] poly )
	{
		bool inside = false;
		for ( int i = 0, j = poly.Length - 1; i < poly.Length; j = i++ )
		{
			var a = poly[i];
			var b = poly[j];
			if ( (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x )
				inside = !inside;
		}
		return inside;
	}

	public static float Smoothstep( float a, float b, float x )
	{
		var t = Math.Clamp( (x - a) / (b - a), 0f, 1f );
		return t * t * (3f - 2f * t);
	}
}
