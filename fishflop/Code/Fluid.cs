namespace FishFlop;

/// <summary>
/// The water: one continuous velocity field on a grid (Stam-style stable fluids),
/// plus two dyes carried by it. Fish are NOT obstacles in this field; they only
/// read it (drag) and leave a small wake in it. Gravel and the rock are solid.
/// </summary>
public sealed class Fluid
{
	public const int NX = 100;
	public const int NY = 52;
	public const float DX = (Tank.Right - Tank.Left) / NX;
	public const float DY = (Tank.Surface - Tank.Bottom) / NY;

	public readonly float[] U = new float[NX * NY];
	public readonly float[] V = new float[NX * NY];
	public readonly float[] Blood = new float[NX * NY];
	public readonly float[] Tracer = new float[NX * NY];
	public readonly bool[] Solid = new bool[NX * NY];

	/// <summary>Free surface height offset per grid column edge (NX + 1 points).</summary>
	public readonly float[] Surf = new float[NX + 1];
	readonly float[] _surfVel = new float[NX + 1];

	readonly float[] _base = new float[NX * NY];
	readonly float[] _p = new float[NX * NY];
	readonly float[] _pn = new float[NX * NY];
	readonly float[] _div = new float[NX * NY];
	readonly float[] _tmpA = new float[NX * NY];
	readonly float[] _tmpB = new float[NX * NY];

	public Fluid()
	{
		for ( int j = 0; j < NY; j++ )
			for ( int i = 0; i < NX; i++ )
			{
				// a soft standing pattern so the body of water is visible when it moves
				var b = 0.5f + 0.25f * MathF.Sin( i * 0.35f + MathF.Sin( j * 0.21f ) * 2f ) * MathF.Sin( j * 0.29f + i * 0.05f );
				_base[Idx( i, j )] = b;
				Tracer[Idx( i, j )] = b;

				var c = CellCenter( i, j );
				if ( c.y < Tank.GravelTop )
					Solid[Idx( i, j )] = true;
				foreach ( var piece in Tank.ArchPieces )
				{
					var local = c - Tank.ArchBase;
					if ( Tank.PointInPolygon( local, piece ) )
						Solid[Idx( i, j )] = true;
				}
			}
	}

	public static int Idx( int i, int j ) => j * NX + i;

	public static Vector2 CellCenter( int i, int j ) => new( Tank.Left + (i + 0.5f) * DX, Tank.Bottom + (j + 0.5f) * DY );

	public void Reset()
	{
		Array.Clear( U );
		Array.Clear( V );
		Array.Clear( Blood );
		Array.Clear( _p );
		Array.Clear( Surf );
		Array.Clear( _surfVel );
		Array.Copy( _base, Tracer, _base.Length );
	}

	public float SurfaceAt( float x )
	{
		var cx = (x - Tank.Left) / DX;
		var i = (int)Math.Clamp( cx, 0, NX - 1 );
		var f = Math.Clamp( cx - i, 0f, 1f );
		return Tank.Surface + Surf[i] * (1 - f) + Surf[i + 1] * f;
	}

	public float Sample( float[] f, float x, float y )
	{
		var cx = Math.Clamp( (x - Tank.Left) / DX - 0.5f, 0f, NX - 1.001f );
		var cy = Math.Clamp( (y - Tank.Bottom) / DY - 0.5f, 0f, NY - 1.001f );
		int i = (int)cx, j = (int)cy;
		float fx = cx - i, fy = cy - j;
		return f[Idx( i, j )] * (1 - fx) * (1 - fy) + f[Idx( i + 1, j )] * fx * (1 - fy)
			+ f[Idx( i, j + 1 )] * (1 - fx) * fy + f[Idx( i + 1, j + 1 )] * fx * fy;
	}

	public Vector2 Velocity( Vector2 p ) => new( Sample( U, p.x, p.y ), Sample( V, p.x, p.y ) );

	/// <summary>Pull water towards a target velocity inside a soft radius. Bounded: water never moves faster than the fist.</summary>
	public void DragTo( Vector2 p, Vector2 target, float radius, float strength )
	{
		ForEachNear( p, radius * 2.2f, ( k, w ) =>
		{
			var a = w * strength;
			U[k] += (target.x - U[k]) * a;
			V[k] += (target.y - V[k]) * a;
		}, radius );
	}

	/// <summary>Add velocity (wake) and/or dye around a point.</summary>
	public void Splat( Vector2 p, Vector2 add, float radius, float dye = 0f )
	{
		ForEachNear( p, radius * 2.2f, ( k, w ) =>
		{
			U[k] += add.x * w;
			V[k] += add.y * w;
			Blood[k] += dye * w;
		}, radius );
	}

	/// <summary>Outward shockwave, for the punch.</summary>
	public void Radial( Vector2 p, float strength, float radius )
	{
		var r0 = (int)MathF.Ceiling( radius * 2.2f / DX );
		var (ci, cj) = CellOf( p );
		for ( int j = Math.Max( 0, cj - r0 ); j <= Math.Min( NY - 1, cj + r0 ); j++ )
			for ( int i = Math.Max( 0, ci - r0 ); i <= Math.Min( NX - 1, ci + r0 ); i++ )
			{
				var d = CellCenter( i, j ) - p;
				var len = d.Length + 0.001f;
				var w = MathF.Exp( -(len * len) / (radius * radius) );
				var k = Idx( i, j );
				U[k] += d.x / len * strength * w;
				V[k] += d.y / len * strength * w;
			}
	}

	(int, int) CellOf( Vector2 p ) => ((int)((p.x - Tank.Left) / DX), (int)((p.y - Tank.Bottom) / DY));

	void ForEachNear( Vector2 p, float reach, Action<int, float> fn, float radius )
	{
		var r0 = (int)MathF.Ceiling( reach / MathF.Min( DX, DY ) );
		var (ci, cj) = CellOf( p );
		var inv = 1f / (radius * radius);
		for ( int j = Math.Max( 0, cj - r0 ); j <= Math.Min( NY - 1, cj + r0 ); j++ )
			for ( int i = Math.Max( 0, ci - r0 ); i <= Math.Min( NX - 1, ci + r0 ); i++ )
			{
				var k = Idx( i, j );
				if ( Solid[k] ) continue;
				var d = CellCenter( i, j ) - p;
				fn( k, MathF.Exp( -d.LengthSquared * inv ) );
			}
	}

	public void Step( float dt )
	{
		Walls();

		Advect( U, _tmpA, dt );
		Advect( V, _tmpB, dt );
		for ( int k = 0; k < U.Length; k++ )
		{
			U[k] = _tmpA[k] * 0.995f;
			V[k] = _tmpB[k] * 0.995f;
		}
		Walls();
		Project();
		Walls();

		Advect( Tracer, _tmpA, dt );
		for ( int k = 0; k < Tracer.Length; k++ )
			Tracer[k] = _tmpA[k] + (_base[k] - _tmpA[k]) * 0.01f;

		Advect( Blood, _tmpA, dt );
		for ( int k = 0; k < Blood.Length; k++ )
			Blood[k] = _tmpA[k] * 0.9993f;

		StepSurface( dt );
	}

	void Project()
	{
		var h2 = DX * DY;
		for ( int j = 1; j < NY - 1; j++ )
			for ( int i = 1; i < NX - 1; i++ )
			{
				var k = Idx( i, j );
				_div[k] = (U[k + 1] - U[k - 1]) / (2 * DX) + (V[k + NX] - V[k - NX]) / (2 * DY);
			}

		for ( int k = 0; k < _p.Length; k++ ) _p[k] *= 0.9f; // warm start

		for ( int it = 0; it < 24; it++ )
		{
			for ( int j = 1; j < NY - 1; j++ )
				for ( int i = 1; i < NX - 1; i++ )
				{
					var k = Idx( i, j );
					_pn[k] = (_p[k + 1] + _p[k - 1] + _p[k + NX] + _p[k - NX] - _div[k] * h2) * 0.25f;
				}
			for ( int j = 0; j < NY; j++ )
			{
				_pn[Idx( 0, j )] = _pn[Idx( 1, j )];
				_pn[Idx( NX - 1, j )] = _pn[Idx( NX - 2, j )];
			}
			for ( int i = 0; i < NX; i++ )
			{
				_pn[Idx( i, 0 )] = _pn[Idx( i, 1 )];
				_pn[Idx( i, NY - 1 )] = 0; // free surface
			}
			Array.Copy( _pn, _p, _p.Length );
		}

		for ( int j = 1; j < NY - 1; j++ )
			for ( int i = 1; i < NX - 1; i++ )
			{
				var k = Idx( i, j );
				U[k] -= (_p[k + 1] - _p[k - 1]) / (2 * DX);
				V[k] -= (_p[k + NX] - _p[k - NX]) / (2 * DY);
			}
	}

	void Advect( float[] src, float[] dst, float dt )
	{
		for ( int j = 0; j < NY; j++ )
			for ( int i = 0; i < NX; i++ )
			{
				var k = Idx( i, j );
				var x = Math.Clamp( i - U[k] * dt / DX, 0f, NX - 1.001f );
				var y = Math.Clamp( j - V[k] * dt / DY, 0f, NY - 1.001f );
				int i0 = (int)x, j0 = (int)y;
				float fx = x - i0, fy = y - j0;
				dst[k] = src[Idx( i0, j0 )] * (1 - fx) * (1 - fy) + src[Idx( i0 + 1, j0 )] * fx * (1 - fy)
					+ src[Idx( i0, j0 + 1 )] * (1 - fx) * fy + src[Idx( i0 + 1, j0 + 1 )] * fx * fy;
			}
	}

	void Walls()
	{
		for ( int j = 0; j < NY; j++ )
		{
			U[Idx( 0, j )] = 0;
			U[Idx( NX - 1, j )] = 0;
		}
		for ( int i = 0; i < NX; i++ )
			V[Idx( i, 0 )] = 0;
		for ( int k = 0; k < U.Length; k++ )
		{
			if ( !Solid[k] ) continue;
			U[k] = 0;
			V[k] = 0;
		}
	}

	/// <summary>Surface heightfield: pushed by the top row's vertical flow, then a damped wave.</summary>
	void StepSurface( float dt )
	{
		var top = NY - 1;
		float mean = 0;
		for ( int i = 0; i <= NX; i++ )
		{
			var a = V[Idx( Math.Clamp( i - 1, 0, NX - 1 ), top )];
			var b = V[Idx( Math.Clamp( i, 0, NX - 1 ), top )];
			var vt = (a + b) * 0.5f;
			var lap = (i > 0 && i < NX) ? Surf[i + 1] + Surf[i - 1] - 2 * Surf[i] : 0f;
			_surfVel[i] += (lap * 900f - Surf[i] * 2f) * dt + vt * dt * 0.35f;
			_surfVel[i] *= 0.985f;
		}
		for ( int i = 0; i <= NX; i++ )
		{
			Surf[i] += _surfVel[i] * dt;
			mean += Surf[i];
		}
		mean /= NX + 1;
		for ( int i = 0; i <= NX; i++ )
			Surf[i] = Math.Clamp( Surf[i] - mean, -24f, 24f );
	}
}
