namespace FishFlop;

/// <summary>
/// One rigid piece of a fish: a head, body segment, tail or fin. Each has its own
/// Rigidbody and hull collider(s) matching its slice of the tapered profile.
/// </summary>
public sealed class FishPart
{
	public GameObject Go;
	public Rigidbody Body;
	public string Kind;
	public float S0, S1;
	public float Mass;
	public bool Gore;

	/// <summary>Collision/drag edges in the part's local (already mirrored) space.</summary>
	public readonly List<(Vector2 mid, Vector2 normal, float len)> Edges = new();
	public float Perimeter;

	public Vector2 ToWorld( Vector2 local )
	{
		var w = Go.WorldTransform.PointToWorld( new Vector3( local.x, local.y, 0 ) );
		return new Vector2( w.x, w.y );
	}
}

/// <summary>A sprung, breakable hinge between two parts.</summary>
public sealed class FishJoint
{
	public HingeJoint Hinge;
	public FishPart A, B;
	public float S;
	public string Kind; // spine, tail, fin
	public Vector2 LocalA;
	public bool Broken;
	public float Damage;
	public float Bleed;
	public Vector2 Where;
}

/// <summary>
/// A segmented ragdoll fish. Muscles are the hinge springs: alive fish drive a
/// travelling wave down the spine (plus a bit of thrust), stunned or dying fish
/// flop hard, dead pieces go limp. Water moves every part through drag only.
/// </summary>
public sealed class Fish
{
	public static class Tuning
	{
		public const float InvTauNormal = 9f;     // how fast a side facing the flow is dragged along
		public const float InvTauTangent = 1.2f;  // skin friction
		public const float Wake = 0.010f;
		public const float SwimHz = 2.2f;
		public const float SwimAmpDeg = 22f;
		public const float MuscleHz = 5f;
		public const float LimpHz = 1.6f;
		public const float FinHz = 3f;
		public const float Damping = 0.35f;
		public const float BreakForce = 5200f;    // per unit of fish mass, s&box force units
		public const float Cruise = 170f;
		public const float ThrustAccel = 900f;
	}

	public readonly FishSpec Spec;
	public readonly int Facing;
	public readonly GameObject Root;
	public readonly List<FishPart> Parts = new();
	public readonly List<FishJoint> Joints = new();
	public readonly float[] Ss;
	public readonly Vector2[] TailOutline;
	public readonly Vector2[] DorsalOutline;
	public readonly Vector2[] PectoralOutline;
	public int DorsalSegment;

	public bool Alive = true;
	public float Dying;
	public float Stun;
	float _t;
	float _turn;
	float _grace;
	Vector2 _goal;
	readonly Random _rng;
	readonly TankGame _tank;

	public FishPart Head => Parts[0];
	public FishPart TailFin => Parts[Spec.Segments];
	public FishPart Dorsal => Parts[Spec.Segments + 1];
	public FishPart Pectoral => Parts[Spec.Segments + 2];

	public Fish( TankGame tank, FishSpec spec, Vector2 origin, int facing, Random rng )
	{
		_tank = tank;
		Spec = spec;
		Facing = facing;
		_rng = rng;
		_t = (float)rng.NextDouble() * 10f;
		_goal = origin;

		Root = tank.Scene.CreateObject();
		Root.Name = $"Fish ({spec.Name})";
		Root.WorldPosition = new Vector3( origin.x, origin.y, 0 );

		int n = spec.Segments;
		Ss = new float[n + 1];
		Ss[0] = 0;
		Ss[1] = spec.HeadFrac;
		for ( int k = 2; k <= n; k++ )
			Ss[k] = spec.HeadFrac + (1 - spec.HeadFrac) * (k - 1) / (n - 1);

		// body segments: each hull is the profile between its two spine stations
		var segPolys = new List<Vector2[]>();
		float totalArea = 0;
		for ( int k = 0; k < n; k++ )
		{
			var poly = SegmentPolygon( Ss[k], Ss[k + 1] );
			segPolys.Add( poly );
			totalArea += MathF.Abs( Area( poly ) );
		}
		for ( int k = 0; k < n; k++ )
		{
			var m = spec.Mass * MathF.Abs( Area( segPolys[k] ) ) / totalArea * 0.86f;
			MakePart( k == 0 ? "head" : "body", new[] { segPolys[k] }, m, Ss[k], Ss[k + 1] );
		}

		// forked tail: two convex lobes on one body; base tucked just inside the peduncle
		var ped = spec.H( 1f );
		var bx = spec.X( 1f ) + 0.01f * spec.Length;
		float tl = spec.TailLength, th = spec.TailHeight, fork = spec.Fork;
		var upper = new Vector2[] { new( bx, ped.top ), new( bx - tl, th ), new( bx - tl * fork, 0 ), new( bx, 0 ) };
		var lower = new Vector2[] { new( bx, 0 ), new( bx - tl * fork, 0 ), new( bx - tl, -th ), new( bx, -ped.bottom ) };
		TailOutline = new Vector2[]
		{
			new( bx + 2, ped.top * 0.9f ), new( bx - tl * 0.55f, th * 0.7f ), new( bx - tl, th ), new( bx - tl * 0.85f, th * 0.55f ),
			new( bx - tl * fork, 0 ),
			new( bx - tl * 0.85f, -th * 0.55f ), new( bx - tl, -th ), new( bx - tl * 0.55f, -th * 0.7f ), new( bx + 2, -ped.bottom * 0.9f ),
		};
		MakePart( "tail", new[] { upper, lower }, spec.Mass * 0.07f, 1f, 1f );

		// dorsal fin rides on one mid segment only, so its base never spans a bending joint
		var dMid = (spec.DorsalStart + spec.DorsalEnd) * 0.5f;
		DorsalSegment = 1;
		for ( int k = 1; k < n; k++ )
			if ( Ss[k] <= dMid && dMid <= Ss[k + 1] ) DorsalSegment = k;
		var a0 = MathF.Max( Ss[DorsalSegment] + 0.01f, spec.DorsalStart );
		var a1 = MathF.Min( Ss[DorsalSegment + 1] - 0.01f, spec.DorsalEnd );
		var top0 = spec.H( a0 ).top;
		var top1 = spec.H( a1 ).top;
		var dh = spec.DorsalHeight * spec.HalfHeight;
		DorsalOutline = new Vector2[]
		{
			new( spec.X( a0 ), top0 - 3 ),
			new( spec.X( a0 ) - (spec.X( a0 ) - spec.X( a1 )) * 0.25f, top0 + dh ),
			new( spec.X( a1 ), top1 + dh * 0.35f ),
			new( spec.X( a1 ), top1 - 3 ),
		};
		MakePart( "dorsal", new[] { DorsalOutline }, spec.Mass * 0.03f, a0, a1 );

		// pectoral fin on the side of the head, drawn over the body
		var hs = spec.HeadFrac * 0.92f;
		var px = spec.X( hs );
		var py = -spec.HalfHeight * 0.15f;
		// a fan: narrow root behind the gill, spreading back and down to a rounded edge
		PectoralOutline = new Vector2[]
		{
			new( px + 1, py + 3 ),
			new( px - spec.Length * 0.12f, py - spec.HalfHeight * 0.05f ),
			new( px - spec.Length * 0.145f, py - spec.HalfHeight * 0.24f ),
			new( px - spec.Length * 0.11f, py - spec.HalfHeight * 0.42f ),
			new( px + 1, py - 3 ),
		};
		MakePart( "pectoral", new[] { PectoralOutline }, spec.Mass * 0.02f, hs, hs );

		for ( int k = 0; k < n - 1; k++ )
			AddJoint( Parts[k], Parts[k + 1], new Vector2( spec.X( Ss[k + 1] ), 0 ), Ss[k + 1], "spine", 38 );
		AddJoint( Parts[n - 1], TailFin, new Vector2( spec.X( 1f ), 0 ), 1f, "tail", 40 );
		AddJoint( Parts[DorsalSegment], Dorsal, new Vector2( spec.X( a0 ), top0 - 2 ), a0, "fin", 25 );
		AddJoint( Head, Pectoral, new Vector2( px, py ), hs, "fin", 45 );

		// side fins are out of the body's plane: they must not shove their own body around
		Filter( Pectoral, Parts[1] );
		if ( n > 2 ) Filter( Pectoral, Parts[2] );
		if ( DorsalSegment > 0 ) Filter( Dorsal, Parts[DorsalSegment - 1] );
		if ( DorsalSegment + 1 < n ) Filter( Dorsal, Parts[DorsalSegment + 1] );
		if ( n > 2 ) Filter( TailFin, Parts[n - 2] );
	}

	Vector2[] SegmentPolygon( float s0, float s1 )
	{
		const int steps = 3;
		var pts = new List<Vector2>();
		var ss = new float[steps + 1];
		for ( int i = 0; i <= steps; i++ ) ss[i] = s0 + (s1 - s0) * i / steps;
		if ( s0 <= 0 ) ss[0] = 0.02f;
		foreach ( var s in ss ) pts.Add( new Vector2( Spec.X( s ), Spec.H( s ).top ) );
		for ( int i = steps; i >= 0; i-- ) pts.Add( new Vector2( Spec.X( ss[i] ), -Spec.H( ss[i] ).bottom ) );
		return pts.ToArray();
	}

	/// <summary>Rest-pose point (fish facing +X) into this fish's mirrored local space.</summary>
	public Vector2 M( Vector2 p ) => new( p.x * Facing, p.y );

	FishPart MakePart( string kind, Vector2[][] polys, float mass, float s0, float s1 )
	{
		var go = _tank.Scene.CreateObject();
		go.Name = kind;
		go.Parent = Root;
		go.WorldPosition = Root.WorldPosition;
		go.WorldRotation = Rotation.Identity;

		var rb = go.Components.Create<Rigidbody>();
		rb.Gravity = false; // gravity and buoyancy are applied by the water
		rb.MassOverride = mass;
		rb.LinearDamping = 0f;
		rb.AngularDamping = 0.6f;

		var part = new FishPart { Go = go, Body = rb, Kind = kind, S0 = s0, S1 = s1, Mass = mass };

		foreach ( var poly in polys )
		{
			var local = poly.Select( M ).ToList();
			if ( Area( local.ToArray() ) < 0 ) local.Reverse(); // keep CCW so normals point out

			var hull = go.Components.Create<HullCollider>( false );
			hull.Type = HullCollider.PrimitiveType.Points;
			hull.Points = local.Select( p => new Vector3( p.x, p.y, 0 ) ).ToList();
			hull.Friction = 0.35f;
			hull.Elasticity = 0.1f;
			hull.Enabled = true;

			for ( int i = 0; i < local.Count; i++ )
			{
				var a = local[i];
				var b = local[(i + 1) % local.Count];
				var e = b - a;
				var len = e.Length;
				if ( len < 0.001f ) continue;
				part.Edges.Add( ((a + b) * 0.5f, new Vector2( e.y, -e.x ) / len, len) );
				part.Perimeter += len;
			}
		}

		Parts.Add( part );
		return part;
	}

	void AddJoint( FishPart a, FishPart b, Vector2 restLocal, float s, string kind, float limitDeg )
	{
		var local = M( restLocal );
		var world = a.ToWorld( local );

		var pivotA = _tank.Scene.CreateObject();
		pivotA.Name = $"{kind} joint";
		pivotA.Parent = a.Go;
		pivotA.WorldPosition = new Vector3( world.x, world.y, 0 );
		pivotA.WorldRotation = Rotation.Identity;

		var pivotB = _tank.Scene.CreateObject();
		pivotB.Name = $"{kind} anchor";
		pivotB.Parent = b.Go;
		pivotB.WorldPosition = new Vector3( world.x, world.y, 0 );
		pivotB.WorldRotation = Rotation.Identity;

		var fj = new FishJoint { A = a, B = b, S = s, Kind = kind, LocalA = local };

		var hinge = pivotA.Components.Create<HingeJoint>( false );
		hinge.Body = pivotB;
		hinge.EnableCollision = false;
		hinge.LimitEnabled = true;
		hinge.MinAngle = -limitDeg;
		hinge.MaxAngle = limitDeg;
		hinge.Motor = HingeJoint.MotorMode.TargetAngle;
		hinge.Frequency = kind == "fin" ? Tuning.FinHz : Tuning.MuscleHz;
		hinge.DampingRatio = Tuning.Damping;
		hinge.TargetAngle = 0;
		// hard backstop; normal breaking is the damage model in CheckBreaks
		hinge.BreakForce = Tuning.BreakForce * Spec.Mass * 2.5f;
		hinge.OnBreak = () => OnJointBroken( fj );
		hinge.Enabled = true;

		fj.Hinge = hinge;
		Joints.Add( fj );
	}

	void Filter( FishPart a, FishPart b )
	{
		var f = a.Go.Components.Create<PhysicsFilter>( false );
		f.Body = b.Go;
		f.Enabled = true;
	}

	public void Destroy() => Root.Destroy();

	// ------------------------------------------------------------------ simulation

	public void Tick( float dt, Fluid fluid )
	{
		_t += dt;
		Stun = MathF.Max( 0, Stun - dt );
		Dying = MathF.Max( 0, Dying - dt );
		_grace = MathF.Max( 0, _grace - dt );

		var connected = ConnectedToHead();
		Think( dt, fluid );
		Muscles( connected );
		foreach ( var p in Parts )
			Couple( p, dt, fluid );
		CheckBreaks( dt, fluid );
	}

	HashSet<FishPart> ConnectedToHead()
	{
		var seen = new HashSet<FishPart> { Head };
		var stack = new Stack<FishPart>();
		stack.Push( Head );
		while ( stack.Count > 0 )
		{
			var p = stack.Pop();
			foreach ( var j in Joints )
			{
				if ( j.Broken ) continue;
				if ( j.A == p && seen.Add( j.B ) ) stack.Push( j.B );
				if ( j.B == p && seen.Add( j.A ) ) stack.Push( j.A );
			}
		}
		return seen;
	}

	float HeadingRad()
	{
		var yaw = Head.Go.WorldRotation.Angles().yaw * MathF.PI / 180f;
		return Facing > 0 ? yaw : yaw + MathF.PI;
	}

	void Think( float dt, Fluid fluid )
	{
		if ( !Alive ) return;

		var center = Head.Body.WorldTransform.PointToWorld( Head.Body.MassCenter );
		var hx = center.x;
		var hy = center.y;
		if ( (_goal - new Vector2( hx, hy )).Length < 80 || _rng.NextDouble() < dt * 0.08f )
		{
			_goal = new Vector2(
				Tank.Left + 150 + (float)_rng.NextDouble() * (Tank.Right - Tank.Left - 300),
				Tank.GravelTop + 90 + (float)_rng.NextDouble() * (Tank.Surface - Tank.GravelTop - 180) );
		}

		var heading = HeadingRad();
		var want = MathF.Atan2( _goal.y - hy, _goal.x - hx );
		var err = want - heading;
		while ( err > MathF.PI ) err -= 2 * MathF.PI;
		while ( err < -MathF.PI ) err += 2 * MathF.PI;
		_turn += (Math.Clamp( err, -0.6f, 0.6f ) - _turn) * MathF.Min( 1f, dt * 2f );

		// no swimming while stunned or out of the water
		if ( Stun > 0 || hy > fluid.SurfaceAt( hx ) ) return;

		var flow = fluid.Velocity( new Vector2( hx, hy ) );
		var dir = new Vector2( MathF.Cos( heading ), MathF.Sin( heading ) );
		var v = (Vector2)Head.Body.Velocity;
		var vrel = Vector2.Dot( v - flow, dir );
		if ( vrel < Tuning.Cruise )
		{
			var beat = 0.6f + 0.4f * MathF.Abs( MathF.Sin( _t * 2 * MathF.PI * Tuning.SwimHz ) );
			var f = Spec.Mass * Tuning.ThrustAccel * beat * (1 - MathF.Max( vrel, 0 ) / Tuning.Cruise);
			Head.Body.ApplyForce( new Vector3( dir.x * f, dir.y * f, 0 ) );
		}
	}

	void Muscles( HashSet<FishPart> connected )
	{
		foreach ( var j in Joints )
		{
			if ( j.Broken || !j.Hinge.IsValid() ) continue;

			float target, hz, damping = Tuning.Damping;
			var driven = Alive && connected.Contains( j.B );
			if ( j.Kind == "fin" )
			{
				target = MathF.Sin( _t * 7 + j.S * 9 ) * 0.25f;
				hz = Tuning.FinHz;
			}
			else if ( driven && Stun <= 0 )
			{
				// travelling wave, amplitude growing towards the tail, plus steering bend
				target = Tuning.SwimAmpDeg * MathF.PI / 180f * (0.35f + j.S)
					* MathF.Sin( _t * 2 * MathF.PI * Tuning.SwimHz - j.S * 5.5f );
				target += -_turn * 0.5f * Facing;
				hz = Tuning.MuscleHz;
			}
			else if ( driven || Dying > 0 )
			{
				// the flop: whole-body C-bends whipping side to side
				target = 36f * MathF.PI / 180f * MathF.Sin( _t * 2 * MathF.PI * 3.2f - j.S * 2.5f )
					* (0.6f + 0.4f * MathF.Sin( _t * 1.7f ));
				hz = Tuning.MuscleHz;
			}
			else
			{
				target = 0;
				hz = Tuning.LimpHz;
				damping = 0.5f;
			}

			// Box2D's revolute angle is B relative to A; mirrored fish bend the other way
			j.Hinge.TargetAngle = target * Facing * 180f / MathF.PI;
			j.Hinge.Frequency = hz;
			j.Hinge.DampingRatio = damping;
		}
	}

	void Couple( FishPart p, float dt, Fluid fluid )
	{
		var rb = p.Body;
		if ( !rb.IsValid() ) return;

		var c3 = rb.WorldTransform.PointToWorld( rb.MassCenter );
		var c = new Vector2( c3.x, c3.y );
		var m = p.Mass;
		var g = Tank.Gravity;

		if ( c.y > fluid.SurfaceAt( c.x ) )
		{
			rb.ApplyForce( new Vector3( 0, -m * g, 0 ) ); // out of the water: it just falls
			return;
		}

		// living fish are neutrally buoyant; dead bits slowly sink to the gravel
		var buoyancy = Alive && !p.Gore ? 1f : 0.92f;
		rb.ApplyForce( new Vector3( 0, -m * g * (1 - buoyancy), 0 ) );

		var rot = p.Go.WorldRotation;
		Vector2 total = Vector2.Zero;
		foreach ( var (mid, normal, len) in p.Edges )
		{
			var w3 = p.Go.WorldTransform.PointToWorld( new Vector3( mid.x, mid.y, 0 ) );
			var wp = new Vector2( w3.x, w3.y );
			var n3 = rot * new Vector3( normal.x, normal.y, 0 );
			var n = new Vector2( n3.x, n3.y );

			var vb = (Vector2)rb.GetVelocityAtPoint( w3 );
			var rel = fluid.Velocity( wp ) - vb;
			var vn = Vector2.Dot( rel, n );
			var vt = rel - n * vn;

			// relaxation drag: flat sides facing the flow catch it fast, skin friction is slow
			var share = m * len / p.Perimeter;
			var kn = vn < 0 ? Tuning.InvTauNormal : Tuning.InvTauNormal * 0.15f;
			var f = (n * (kn * vn) + vt * Tuning.InvTauTangent) * share;
			rb.ApplyForceAt( w3, new Vector3( f.x, f.y, 0 ) );
			total += f;
		}

		// the wake: an equal and opposite nudge into the water, no cavity
		fluid.Splat( c, -total * Tuning.Wake * dt, 28 );
	}

	void CheckBreaks( float dt, Fluid fluid )
	{
		FishJoint worst = null;
		float worstR = 0;

		foreach ( var j in Joints )
		{
			if ( j.Broken )
			{
				if ( j.Bleed > 0.01f && j.A.Go.IsValid() )
				{
					j.Where = j.A.ToWorld( j.LocalA );
					fluid.Splat( j.Where, Vector2.Zero, 22, j.Bleed * dt * 3 );
					j.Bleed *= MathF.Exp( -dt / 3f );
				}
				continue;
			}
			if ( !j.Hinge.IsValid() ) continue;

			var lim = Tuning.BreakForce * Spec.Mass * (j.Kind == "fin" ? 0.5f : 1f);
			var force = j.Hinge.LinearStress;
			if ( force > lim * 0.35f )
			{
				j.Damage += (force - lim * 0.35f) / (lim * 0.65f);
				Stun = MathF.Max( Stun, 1.8f );
			}
			var r = MathF.Max( force / lim, j.Damage );
			if ( r > 1f && r > worstR )
			{
				worst = j;
				worstR = r;
			}
		}

		// one break per fish per step, so a slam splits it into chunks instead of confetti
		if ( worst != null && _grace <= 0 )
		{
			worst.Hinge.Break();
			_grace = 0.12f;
			foreach ( var j in Joints )
				if ( !j.Broken ) j.Damage = MathF.Min( j.Damage, 0.6f );
		}
	}

	void OnJointBroken( FishJoint j )
	{
		if ( j.Broken ) return;
		j.Broken = true;
		j.Where = j.A.ToWorld( j.LocalA );
		j.Bleed = j.Kind == "fin" ? 0.25f : 1f;
		_tank.Fluid.Splat( j.Where, Vector2.Zero, 30, j.Kind == "fin" ? 0.6f : 2.5f );

		if ( Alive && j.Kind == "spine" )
		{
			var connected = ConnectedToHead();
			int kept = 0;
			for ( int k = 1; k < Spec.Segments; k++ )
				if ( connected.Contains( Parts[k] ) ) kept++;
			if ( kept < (Spec.Segments - 1) * 0.6f )
			{
				Alive = false;
				Dying = 3.5f;
			}
		}

		// anything no longer attached to a living head is gore from now on
		var still = ConnectedToHead();
		foreach ( var p in Parts )
			if ( !Alive || !still.Contains( p ) ) p.Gore = true;
	}

	static float Area( Vector2[] pts )
	{
		float a = 0;
		for ( int i = 0; i < pts.Length; i++ )
		{
			var p = pts[i];
			var q = pts[(i + 1) % pts.Length];
			a += p.x * q.y - q.x * p.y;
		}
		return a * 0.5f;
	}
}
