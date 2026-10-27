// Unlit vertex colour with alpha. Depth is ignored on purpose: the tank is
// drawn back-to-front in one pass by TankRenderer, painter's algorithm.
HEADER
{
	Description = "Fishy Flop unlit vertex colour";
}

FEATURES
{
	#include "common/features.hlsl"
}

MODES
{
	Forward();
}

COMMON
{
	#include "common/shared.hlsl"
}

struct VertexInput
{
	#include "common/vertexinput.hlsl"
	float4 vColor : COLOR0 < Semantic( Color ); >;
};

struct PixelInput
{
	#include "common/pixelinput.hlsl"
	float4 vFlatColor : TEXCOORD14;
};

VS
{
	#include "common/vertex.hlsl"

	PixelInput MainVs( VertexInput i )
	{
		PixelInput o = ProcessVertex( i );
		o.vFlatColor = i.vColor;
		return FinalizeVertex( o );
	}
}

PS
{
	#include "common/pixel.hlsl"

	RenderState( CullMode, NONE );
	RenderState( DepthEnable, false );
	RenderState( DepthWriteEnable, false );
	RenderState( BlendEnable, true );
	RenderState( SrcBlend, SRC_ALPHA );
	RenderState( DstBlend, INV_SRC_ALPHA );

	float4 MainPs( PixelInput i ) : SV_Target0
	{
		// vertex colours are authored in sRGB
		float3 c = pow( saturate( i.vFlatColor.rgb ), 2.2 );
		return float4( c, i.vFlatColor.a );
	}
}
