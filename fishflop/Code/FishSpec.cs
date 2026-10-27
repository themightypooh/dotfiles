namespace FishFlop;

/// <summary>
/// Shape and look of one kind of fish. The body is a tapered profile, widest
/// near the head, pinching to a peduncle that carries a forked tail. Spine
/// parameter s runs 0 (snout) to 1 (tail root).
/// </summary>
public sealed class FishSpec
{
	public string Name;
	public float Length;
	public float HalfHeight;      // at the widest point
	public float Peak;            // s of the widest point
	public float Peduncle;        // tail-root half height, as a fraction of HalfHeight
	public int Segments;          // head + body segments
	public float HeadFrac;        // s where the head ends
	public float TailLength, TailHeight, Fork; // fork: 0 = straight edge, 1 = deep V
	public float DorsalStart = 0.35f, DorsalEnd = 0.6f, DorsalHeight = 0.35f;
	public float Mass = 1f;
	public Color32 Back, Belly, FinColor;
	public Color32? Stripe;

	float _a;

	public void Init()
	{
		_a = MathF.Log( 0.5f ) / MathF.Log( Peak );
	}

	/// <summary>Half heights (top, bottom) at s.</summary>
	public (float top, float bottom) H( float s )
	{
		var sc = Math.Clamp( s, 1e-4f, 1f );
		var baseF = MathF.Pow( MathF.Max( MathF.Sin( MathF.PI * MathF.Pow( sc, _a ) ), 0f ), 0.72f );
		var q = Tank.Smoothstep( 0.62f, 1f, s );
		var f = (1 - q) * baseF + q * Peduncle;
		if ( s > 0.6f ) f = MathF.Max( f, Peduncle );
		return (HalfHeight * f * 1.08f, HalfHeight * f * 0.92f);
	}

	/// <summary>Rest-pose x of spine parameter s, fish facing +X, origin at mid-length.</summary>
	public float X( float s ) => Length * (0.5f - s);

	public static readonly FishSpec Goldie = Make( new FishSpec
	{
		Name = "goldie",
		Length = 150,
		HalfHeight = 0.21f * 150,
		Peak = 0.32f,
		Peduncle = 0.22f,
		Segments = 5,
		HeadFrac = 0.30f,
		TailLength = 62,
		TailHeight = 40,
		Fork = 0.42f,
		Back = new Color32( 190, 80, 20 ),
		Belly = new Color32( 255, 196, 120 ),
		FinColor = new Color32( 240, 120, 40 ),
	} );

	public static readonly FishSpec Mackerel = Make( new FishSpec
	{
		Name = "mackerel",
		Length = 210,
		HalfHeight = 0.11f * 210,
		Peak = 0.28f,
		Peduncle = 0.16f,
		Segments = 6,
		HeadFrac = 0.24f,
		TailLength = 64,
		TailHeight = 44,
		Fork = 0.62f,
		Back = new Color32( 40, 70, 95 ),
		Belly = new Color32( 225, 232, 238 ),
		FinColor = new Color32( 90, 110, 130 ),
		Stripe = new Color32( 25, 40, 55 ),
		DorsalHeight = 0.5f,
	} );

	public static readonly FishSpec Tang = Make( new FishSpec
	{
		Name = "tang",
		Length = 120,
		HalfHeight = 0.29f * 120,
		Peak = 0.40f,
		Peduncle = 0.25f,
		Segments = 4,
		HeadFrac = 0.34f,
		TailLength = 40,
		TailHeight = 30,
		Fork = 0.25f,
		Back = new Color32( 230, 190, 20 ),
		Belly = new Color32( 255, 230, 90 ),
		FinColor = new Color32( 240, 200, 30 ),
		DorsalStart = 0.3f,
		DorsalEnd = 0.62f,
		DorsalHeight = 0.3f,
	} );

	static FishSpec Make( FishSpec s )
	{
		s.Init();
		return s;
	}
}
