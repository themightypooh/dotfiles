namespace FishFlop;

/// <summary>Pixel-art clenched fist, drawn on the HUD at the mouse position.</summary>
public sealed class FistCursor
{
	// o outline, h highlight, s skin, d shadow
	static readonly string[] Art =
	{
		"..oooooooooooo..",
		".ohhsohhsohhsoo.",
		".ohssohssohssoso",
		".osssosssosssoso",
		".osssosssosssoso",
		".oddsodssodssodo",
		".ooooooooooooodo",
		".ohhhhhhhhhsssdo",
		".osssssssssssdo.",
		"..oddsssssssdo..",
		"...ooddddddoo...",
		"....osssssso....",
		"....osssssso....",
		"....oooooooo....",
	};

	float _punch;

	public void Punch() => _punch = 0.14f;

	public void Draw( HudPainter hud, Vector2 mouse, bool clenched, float dt )
	{
		_punch = MathF.Max( 0, _punch - dt );
		var px = MathF.Max( 2f, MathF.Round( Screen.Height / 300f ) );
		if ( clenched ) px *= 1.1f;
		if ( _punch > 0 ) px *= 1.35f;

		var skin = clenched ? new Color( 0.95f, 0.62f, 0.50f ) : new Color( 0.92f, 0.71f, 0.53f );
		var hi = new Color( 1f, 0.86f, 0.71f );
		var sh = new Color( 0.70f, 0.47f, 0.33f );
		var ol = new Color( 0.16f, 0.09f, 0.05f );

		// hotspot on the knuckles
		var origin = mouse - new Vector2( 8, 4 ) * px;
		for ( int y = 0; y < Art.Length; y++ )
		{
			var row = Art[y];
			for ( int x = 0; x < row.Length; x++ )
			{
				Color c;
				switch ( row[x] )
				{
					case 'o': c = ol; break;
					case 'h': c = hi; break;
					case 's': c = skin; break;
					case 'd': c = sh; break;
					default: continue;
				}
				hud.DrawRect( new Rect( origin.x + x * px, origin.y + y * px, px + 0.5f, px + 0.5f ), c );
			}
		}
	}
}
