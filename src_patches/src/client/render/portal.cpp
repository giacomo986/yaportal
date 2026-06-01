// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
#include "portal.h"

#include "irrlichttypes_bloated.h"
#include "client/sky.h"
#include "constants.h"
#include "log.h"
#include "client/client.h"
#include "client/clientenvironment.h"
#include "client/clientmap.h"
#include "client/camera.h"
#include "client/content_cao.h"
#include "client/localplayer.h"
#include "util/numeric.h"

#include <ISceneManager.h>
#include <IVideoDriver.h>
#include <ICameraSceneNode.h>
#include <ITexture.h>
#include <S3DVertex.h>
#include <IGPUProgrammingServices.h>
#include <IShaderConstantSetCallBack.h>
#include <IMaterialRendererServices.h>
#include <mt_opengl.h>
#include <cmath>
#include <algorithm>

// Depth of the portal tunnel beyond the inner face of the frame.
// 0 = RTT face flush with inner face; frame block itself provides the tunnel depth.
static constexpr float PORTAL_TUNNEL_DEPTH = 0.0f * BS;

static inline v3f right_of(const PortalInfo &p)
{
	return p.normal.crossProduct(p.up);
}

// -----------------------------------------------------------------------
// PortalRTTData
// -----------------------------------------------------------------------

PortalRTTData::~PortalRTTData()
{
	for (auto *cam : vcam)
		if (cam)
			cam->remove();
}

void PortalRTTData::ensureCameras(scene::ISceneManager *smgr)
{
	for (int i = 0; i < MAX_PORTALS; ++i) {
		if (!vcam[i]) {
			vcam[i] = smgr->addCameraSceneNode(nullptr);
			vcam[i]->bindTargetAndRotation(true);
		}
	}
}

void PortalRTTData::ensureRenderTextures(video::IVideoDriver *driver, v2u32 size)
{
	const PortalManager &pm = PortalManager::get();
	const bool size_changed = (rtex_size != size);
	for (int i = 0; i < MAX_PORTALS; ++i) {
		const bool need = pm.portal(i).active
				&& pm.portal(i).link >= 0
				&& pm.portal(i).link < MAX_PORTALS
				&& pm.portal(pm.portal(i).link).active;
		if (rtex[i] && (size_changed || !need)) {
			driver->removeTexture(rtex[i]);
			rtex[i] = nullptr;
		}
		if (need && !rtex[i]) {
			char name[32];
			snprintf(name, sizeof(name), "portal_rtex_%d", i);
			rtex[i] = driver->addRenderTargetTexture(
				core::dimension2du(size.X, size.Y), name,
				video::ECF_A8R8G8B8);
		}
	}
	rtex_size = size;
}

// -----------------------------------------------------------------------
// Shared helpers (free functions)
// -----------------------------------------------------------------------

static void setVirtualCamera(
	scene::ICameraSceneNode *vcam,
	scene::ICameraSceneNode *mainCam,
	const PortalInfo &src,
	const PortalInfo &dst,
	const v3f *cam_pos_override = nullptr)
{
	v3f ar = right_of(src), au = src.up, an = src.normal;
	v3f br = right_of(dst), bu = dst.up, bn = dst.normal;

	v3f src_surface = src.pos;
	v3f dst_surface = dst.pos;

	// cam_pos_override: pre-computed virtual camera position in render space.
	// Already accounts for the destination frame — use it directly.
	// Without override: mirror the main camera's eye position through the portal.
	v3f vpos;
	if (cam_pos_override) {
		vpos = *cam_pos_override;
	} else {
		v3f rel = mainCam->getAbsolutePosition() - src_surface;
		float lx = rel.dotProduct(ar), ly = rel.dotProduct(au), lz = rel.dotProduct(an);
		vpos = dst_surface + br * (-lx) + bu * ly + bn * (-lz) + bn * (1.0f * BS);
	}

	v3f dir = mainCam->getTarget() - mainCam->getAbsolutePosition();
	dir.normalize();
	float dx = dir.dotProduct(ar), dy = dir.dotProduct(au), dz = dir.dotProduct(an);
	v3f vdir = br * (-dx) + bu * dy + bn * (-dz);

	v3f upv = mainCam->getUpVector();
	float ux = upv.dotProduct(ar), uy = upv.dotProduct(au), uz = upv.dotProduct(an);
	v3f vup = br * (-ux) + bu * uy + bn * (-uz);

	vcam->setPosition(vpos);
	vcam->setTarget(vpos + vdir);
	vcam->setUpVector(vup);

	// Build a float32-precise view matrix from the known-normalized vdir.
	// Avoids buildCameraLookAtMatrixLH's 'zaxis = target - pos' subtraction
	// which loses precision when vpos has large magnitude (other-world portals).
	{
		v3f zaxis = vdir;   // already normalized
		v3f xaxis = vup.crossProduct(zaxis); xaxis.normalize();
		v3f yaxis = zaxis.crossProduct(xaxis);
		core::matrix4 vm;
		float *m = vm.pointer();
		m[0] = xaxis.X; m[4] = xaxis.Y; m[8]  = xaxis.Z; m[12] = -xaxis.dotProduct(vpos);
		m[1] = yaxis.X; m[5] = yaxis.Y; m[9]  = yaxis.Z; m[13] = -yaxis.dotProduct(vpos);
		m[2] = zaxis.X; m[6] = zaxis.Y; m[10] = zaxis.Z; m[14] = -zaxis.dotProduct(vpos);
		m[3] = 0;       m[7] = 0;       m[11] = 0;        m[15] = 1;
		vcam->setRenderViewMatrix(vm);
	}

	vcam->setAspectRatio(mainCam->getAspectRatio());

	v3f vright_axis = vdir.crossProduct(vup);
	vright_axis.normalize();
	vcam->setFOV(mainCam->getFOV());
	vcam->setAspectRatio(mainCam->getAspectRatio());
	vcam->setFarValue(mainCam->getFarValue());
	vcam->setNearValue(mainCam->getNearValue());

	// Oblique near-plane clipping via setRenderProjectionMatrix:
	// The frustum in ViewArea (used for CPU-side entity culling by the SceneManager)
	// is computed by updateMatrices() from ViewArea.ETS_PROJECTION = standard near.
	// setRenderProjectionMatrix overrides only the matrix sent to the driver/shader,
	// so GPU clips at the portal plane while CPU culling sees the full standard frustum.
	//
	// Lengyel technique for Irrlicht LH OpenGL [-1,+1] depth
	// (buildProjectionMatrixPerspectiveFovLH, zClipFromZero=false).
	// Row 3 = (0,0,1,0) → w_clip = z_eye.  Near: z_ndc = -1 = z_clip/w_clip.
	// Modification: new_row2 = λ*c_e - row3, λ = 2/(c_c·q),
	// where c_c = P^{-T}*c_e using P^{-T} derived for this LH matrix.
	{
		// clip_n points from portal surface INTO the scene (away from vcam).
		float side = (vpos - dst_surface).dotProduct(bn);
		// Only apply Lengyel when vcam is on the destination side (side < 0).
		// When side > 0 (vcam on source side, player inside portal), c_e_w can
		// go negative and the oblique near plane ends up behind the camera,
		// clipping all geometry.  The clip is unnecessary there anyway.
		if (side < -0.001f * BS) {
			v3f clip_n = bn;

			// Eye-space plane. Camera basis: right=vup×vdir, up=vup, fwd=vdir (+z_eye in LH).
			// right_eye = vup×vdir = -vright_axis (vright_axis = vdir×vup).
			float c_e_x = -clip_n.dotProduct(vright_axis); // right_eye component
			float c_e_y =  clip_n.dotProduct(vup);
			float c_e_z =  clip_n.dotProduct(vdir);        // +z_eye = forward in LH
			// Clip just inside outer face of dst frame to avoid z-fighting with adjacent blocks.
			v3f clip_origin = dst_surface + bn * (0.49f * BS);
			float c_e_w =  clip_n.dotProduct(vpos - clip_origin); // d_e, verified negative

			if (c_e_z > 1e-4f) {
				core::matrix4 proj = vcam->getProjectionMatrix();
				float *m = proj.pointer();
				// c_c = P^{-T}*c_e for symmetric LH perspective:
				// P^{-T} rows: (1/M[0],0,0,0),(0,1/M[5],0,0),(0,0,0,1/M[14]),(0,0,1,-M[10]/M[14])
				float cc_x = c_e_x / m[0];
				float cc_y = c_e_y / m[5];
				float cc_z = c_e_w / m[14];                        // (1/B)*d_e
				float cc_w = c_e_z - (m[10] / m[14]) * c_e_w;    // c_e_z + (A/|B|)*|d_e|

				float dot_cq = std::abs(cc_x) + std::abs(cc_y) + cc_z + cc_w;
				if (std::abs(dot_cq) > 1e-6f) {
					float lam = 2.0f / dot_cq;
					m[2]  = lam * c_e_x;
					m[6]  = lam * c_e_y;
					m[10] = lam * c_e_z - 1.0f;
					m[14] = lam * c_e_w;
					vcam->setRenderProjectionMatrix(proj);
					return; // projection set, skip clearRenderProjectionMatrix path
				}
			}
		}
		vcam->clearRenderProjectionMatrix();
	}
}

// -----------------------------------------------------------------------
// Portal face shader — computes screen-space UV per fragment so that
// every pixel on any face (regardless of depth/angle) samples the RTT
// at its exact screen position. No per-vertex UV interpolation artifacts.
// -----------------------------------------------------------------------

// Irrlicht's OpenGL3 driver does NOT update gl_ModelViewProjectionMatrix or
// use the fixed-function matrix stack. Position must use the named attribute
// "inVertexPosition" (bound at location EVA_POSITION=0 by MaterialRenderer)
// and the MVP matrix must be uploaded as an explicit uniform.
static const char *PORTAL_VS = R"(
attribute vec3 inVertexPosition;
uniform mat4 uMVP;
void main() {
    gl_Position = uMVP * vec4(inVertexPosition, 1.0);
}
)";

// gl_FragCoord.xy is window-space (y=0 at bottom). Convert to UV:
//   u = x / W,   v = 1 - y / H   (flips Y to match RTT top-at-v=0 convention)
static const char *PORTAL_FS = R"(
uniform sampler2D baseTexture;
uniform vec2 uViewportSize;
void main() {
    vec2 uv = vec2(gl_FragCoord.x / uViewportSize.x,
                   gl_FragCoord.y / uViewportSize.y);
    gl_FragColor = texture2D(baseTexture, uv);
}
)";

namespace {
struct PortalShaderCB : public video::IShaderConstantSetCallBack {
    void OnSetConstants(video::IMaterialRendererServices *srv, s32) override {
        video::IVideoDriver *driver = srv->getVideoDriver();

        // MVP = proj * view * world  (world is identity for our quads)
        core::matrix4 mvp = driver->getTransform(video::ETS_PROJECTION);
        mvp *= driver->getTransform(video::ETS_VIEW);
        mvp *= driver->getTransform(video::ETS_WORLD);
        s32 idx_mvp = srv->getVertexShaderConstantID("uMVP");
        srv->setVertexShaderConstant(idx_mvp, mvp.pointer(), 16);

        // Texture sampler
        s32 idx_tex = srv->getPixelShaderConstantID("baseTexture");
        s32 unit = 0;
        srv->setPixelShaderConstant(idx_tex, &unit, 1);

        // Viewport size for gl_FragCoord normalisation
        core::dimension2du sz = driver->getCurrentRenderTargetSize();
        float vpf[2] = {(float)sz.Width, (float)sz.Height};
        s32 idx_vp = srv->getPixelShaderConstantID("uViewportSize");
        srv->setPixelShaderConstant(idx_vp, vpf, 2);
    }
};
} // namespace

static s32 g_portal_shader_mat = -1;

static void ensurePortalShader(video::IVideoDriver *driver)
{
    if (g_portal_shader_mat >= 0)
        return;
    auto *gpu = driver->getGPUProgrammingServices();
    if (!gpu) {
        g_portal_shader_mat = (s32)video::EMT_SOLID; // fallback
        return;
    }
    static PortalShaderCB cb;
    g_portal_shader_mat = gpu->addHighLevelShaderMaterial(
        PORTAL_VS, PORTAL_FS, "portal_faces", &cb, video::EMT_SOLID);
    if (g_portal_shader_mat < 0)
        g_portal_shader_mat = (s32)video::EMT_SOLID; // fallback
}

// Draw the portal tunnel interior:
//   - 4 inset walls: solid dark colour for 3D depth perception (no texture — walls
//     have vertices at two different depths so screen-space UV interpolation is
//     non-linear in 3D and causes severe distortion at close range).
//   - back face: full-size, RTT with screen-space UV. All 4 vertices are at the
//     same depth so perspective-correct UV interpolation reproduces exact screen
//     positions — zero distortion at any distance.
// side_sign: +1 = camera on +normal side, -1 = camera on -normal side.
static void drawPortalFaces(
	video::IVideoDriver *driver,
	const PortalInfo &src,
	float side_sign,
	video::ITexture *tex,
	scene::ICameraSceneNode *mainCam)
{
	v3f r = right_of(src);
	v3f u = src.up;
	// Shift render start to inner face of frame; pos stays at frame center for camera math.
	v3f c = src.pos - src.normal * (side_sign * 0.5f * BS);
	v3f bk = src.normal * (-side_sign * PORTAL_TUNNEL_DEPTH);

	static constexpr float EPS = 0.005f * BS;
	float hw = src.half_w - EPS;
	float hh = src.half_h - EPS;

	// Irrlicht uses GL_CW as front face. Per-face index to make inner faces CW.
	// Left(0)/Top(3): {0,1,2,0,2,3}. Right(1)/Bottom(2): {0,2,1,0,3,2}.
	static const u16 idx_cw[6]  = {0, 1, 2, 0, 2, 3};
	static const u16 idx_ccw[6] = {0, 2, 1, 0, 3, 2};

	driver->setTransform(video::ETS_WORLD,      core::IdentityMatrix);
	driver->setTransform(video::ETS_VIEW,       mainCam->getViewMatrix());
	driver->setTransform(video::ETS_PROJECTION, mainCam->getProjectionMatrix());

	ensurePortalShader(driver);

	// All 5 faces use the same RTT screen-space shader.
	// gl_FragCoord gives per-fragment UV with zero distortion at any angle/depth.
	video::SMaterial mat;
	mat.ZBuffer         = video::ECFN_LESS;
	mat.ZWriteEnable    = video::EZW_ON;
	mat.BackfaceCulling = false;
	mat.setTexture(0, tex);
	mat.TextureLayers[0].TextureWrapU = video::ETC_CLAMP_TO_EDGE;
	mat.TextureLayers[0].TextureWrapV = video::ETC_CLAMP_TO_EDGE;
	mat.MaterialType = (video::E_MATERIAL_TYPE)g_portal_shader_mat;
	driver->setMaterial(mat);

	// --- 4 walls ---
	{
		v3f wf = src.pos + src.normal * (side_sign * 0.5f * BS);
		v3f walls[4][4] = {
			{ wf-r*hw-u*hh, wf-r*hw+u*hh, c-r*hw+u*hh+bk, c-r*hw-u*hh+bk },  // Left
			{ wf+r*hw-u*hh, wf+r*hw+u*hh, c+r*hw+u*hh+bk, c+r*hw-u*hh+bk },  // Right
			{ wf-r*hw-u*hh, wf+r*hw-u*hh, c+r*hw-u*hh+bk, c-r*hw-u*hh+bk },  // Bottom
			{ wf-r*hw+u*hh, wf+r*hw+u*hh, c+r*hw+u*hh+bk, c-r*hw+u*hh+bk },  // Top
		};
		static const u16 *widx[4] = { idx_cw, idx_ccw, idx_ccw, idx_cw };

		for (int fi = 0; fi < 4; ++fi) {
			video::S3DVertex verts[4];
			for (int i = 0; i < 4; ++i)
				verts[i].Pos = walls[fi][i];
			driver->drawVertexPrimitiveList(verts, 4, widx[fi], 2,
				video::EVT_STANDARD, scene::EPT_TRIANGLES);
		}
	}

	// --- back face ---
	{
		// For vertical portals: 0.01*BS clears the frame back face with a thin margin.
		// For horizontal portals: normal is vertical, terrain is at c ± epsilon, so
		// 0.5*BS pushes the quad to portal center — large depth-test margin, no z-fight.
		float bf_offset = (std::abs(src.normal.Y) > 0.5f) ? 0.5f * BS : 0.01f * BS;
		v3f bp = c + bk + src.normal * (side_sign * bf_offset);
		v3f back[4] = {
			bp - r*src.half_w - u*src.half_h,
			bp + r*src.half_w - u*src.half_h,
			bp + r*src.half_w + u*src.half_h,
			bp - r*src.half_w + u*src.half_h,
		};
		video::S3DVertex verts[4];
		for (int i = 0; i < 4; ++i)
			verts[i].Pos = back[i];
		driver->drawVertexPrimitiveList(verts, 4, idx_ccw, 2,
			video::EVT_STANDARD, scene::EPT_TRIANGLES);
	}
}

// -----------------------------------------------------------------------
// RTT rendering helper (shared by PortalPrepareStep and PortalRenderStep)
// -----------------------------------------------------------------------

static void renderPortalRTTs(
	PortalRTTData &data,
	PipelineContext &ctx,
	scene::ICameraSceneNode *mainCam)
{
	// Record the camera position used for this RTT render so PortalQuadStep can
	// detect an intra-frame teleport and re-render if the camera has since moved.
	data.rtt_cam_pos   = mainCam->getAbsolutePosition();
	data.rtt_cam_valid = true;

	PortalManager &pm = PortalManager::get();
	auto *driver = ctx.device->getVideoDriver();
	auto *smgr   = ctx.device->getSceneManager();

	// Camera offset: Luanti shifts the Irrlicht camera near the world origin to
	// avoid float precision issues. All rendering positions must have this offset
	// subtracted from raw world coords.
	v3f offset = {0.0f, 0.0f, 0.0f};
	if (Camera *game_cam = ctx.client->getCamera())
		offset = intToFloat(game_cam->getOffset(), BS);
	data.cam_offset_world = offset;

	data.ensureCameras(smgr);
	// addCameraSceneNode() sets each new cam as active; restore main cam immediately.
	smgr->setActiveCamera(mainCam);
	data.ensureRenderTextures(driver, ctx.target_size);

	ClientMap &cmap = ctx.client->getEnv().getClientMap();

	// Phase 1: set all virtual cameras and collect their world positions.
	// This must happen before rendering so updatePortalDrawList can see all
	// destination positions at once.
	std::vector<v3f> vcam_world_positions;
	for (int i = 0; i < MAX_PORTALS; ++i) {
		const PortalInfo &src_base = pm.portal(i);
		if (!src_base.active || src_base.link < 0 || src_base.link >= MAX_PORTALS)
			continue;
		const PortalInfo &dst_base = pm.portal(src_base.link);
		if (!dst_base.active || !data.rtex[i] || !data.vcam[i])
			continue;

		PortalInfo src = src_base, dst = dst_base;
		src.pos -= offset;
		dst.pos -= offset;

		// Non-consuming hint: persists across render frames until Lua clears it.
		// Overrides the virtual camera position so the destination portal shows
		// the correct exit view even before the client camera has moved there.
		v3f hint_world;
		if (pm.getCamHint(i, hint_world)) {
			v3f hint_render = hint_world - offset;
			setVirtualCamera(data.vcam[i], mainCam, src, dst, &hint_render);
		} else {
			setVirtualCamera(data.vcam[i], mainCam, src, dst);
		}
		// Flush the scene-graph transform so getAbsolutePosition is up-to-date.
		data.vcam[i]->updateAbsolutePosition();
		// vcam is in render space (offset removed); add offset back for world coords.
		vcam_world_positions.push_back(data.vcam[i]->getAbsolutePosition() + offset);
	}

	// Ensure blocks near each destination portal are in the drawlist so the
	// virtual camera sees terrain even when the portal is behind the main camera.
	cmap.updatePortalDrawList(vcam_world_positions);

	// Phase 2: render each portal RTT.

	for (int i = 0; i < MAX_PORTALS; ++i) {
		const PortalInfo &src = pm.portal(i);
		if (!src.active || src.link < 0 || src.link >= MAX_PORTALS)
			continue;
		if (!pm.portal(src.link).active || !data.rtex[i] || !data.vcam[i])
			continue;

		// Compute 4 frustum clip planes from the virtual camera through the exit
		// portal opening edges.  Each plane passes through vpos and one portal edge,
		// with the normal pointing inward.  gl_ClipDistance[k] >= 0 → inside.
		// This prevents exit-portal frame blocks from leaking into the RTT at
		// oblique viewing angles where the Lengyel near-plane clip is insufficient.
		bool use_clip_planes = false;
		{
			PortalInfo dst_r = pm.portal(src.link);
			dst_r.pos -= offset; // to render space (matches worldPosition in shader)
			v3f pr = right_of(dst_r);
			v3f pu = dst_r.up;
			v3f pc = dst_r.pos;
			float hw = dst_r.half_w, hh = dst_r.half_h;
			// Virtual camera position (render space, set in Phase 1).
			v3f vpos = data.vcam[i]->getAbsolutePosition();
			float apex_side = (vpos - pc).dotProduct(dst_r.normal);
			v3f delta = vpos - pc;
			float lx = delta.dotProduct(pr);
			float ly = delta.dotProduct(pu);
			// Skip clip planes only when the player is fully inside the portal
			// opening: on the destination side AND within width/height bounds.
			// If only the depth condition is met (player at frame level but outside
			// the opening laterally), keep clip planes active to prevent leaking.
			bool player_inside_frame = apex_side > 0.0f
					&& std::abs(lx) < hw
					&& std::abs(ly) < hh;
			if (!player_inside_frame) {
				// Mirror across portal plane: flip only the bn component, preserve lateral.
				// (apex_side <= 0 means no mirror needed, but apply standoff clamp.)
				float side = apex_side;
				if (side > -0.05f * BS)
					vpos -= dst_r.normal * (side + 0.05f * BS);

				// Helper: plane through 'from' and a portal edge (edge_center, edge_dir),
				// normal pointing toward interior_pt.
				// Plane eq: dot(p, n) + d >= 0 → inside.
				// If computed normal tilts backward (nbn < 0): fall back to corridor plane
				// (remove bn component, anchor to edge_center) so destination geometry
				// is never clipped when apex is laterally displaced past the portal edge.
				v3f bn = dst_r.normal;
				auto makePlane = [&bn](v3f from, v3f edge_center, v3f edge_dir,
				                       v3f interior_pt, float *out) {
					v3f v = edge_center - from;
					v3f n = v.crossProduct(edge_dir);
					float len = n.getLength();
					if (len < 1e-6f) {
						out[0] = 0; out[1] = 0; out[2] = 1; out[3] = 1e15f;
						return;
					}
					n /= len;
					if (n.dotProduct(interior_pt - from) < 0) n = -n;

					float nbn = n.dotProduct(bn);
					if (nbn < 0.0f) {
						// Backward tilt: clamp to corridor plane (perpendicular to portal face).
						n -= bn * nbn;
						float nlen = n.getLength();
						if (nlen < 1e-6f) {
							out[0] = 0; out[1] = 0; out[2] = 1; out[3] = 1e15f;
							return;
						}
						n /= nlen;
						float d = -n.dotProduct(edge_center);
						out[0] = n.X; out[1] = n.Y; out[2] = n.Z; out[3] = d;
						return;
					}

					float d = -n.dotProduct(from);
					out[0] = n.X; out[1] = n.Y; out[2] = n.Z; out[3] = d;
				};

				PortalClipPlanes cp;
				cp.active = true;
				makePlane(vpos, pc + pr * hw, pu, pc - pr * hw, &cp.data[0]);  // right
				makePlane(vpos, pc - pr * hw, pu, pc + pr * hw, &cp.data[4]);  // left
				makePlane(vpos, pc + pu * hh, pr, pc - pu * hh, &cp.data[8]);  // top
				makePlane(vpos, pc - pu * hh, pr, pc + pu * hh, &cp.data[12]); // bottom
				pm.setClipPlanes(cp);
				use_clip_planes = true;
			}
		}
		if (use_clip_planes) {
			GL.Enable(GL.CLIP_DISTANCE0);
			GL.Enable(GL.CLIP_DISTANCE1);
			GL.Enable(GL.CLIP_DISTANCE2);
			GL.Enable(GL.CLIP_DISTANCE3);
		}

		// Activate the per-portal sky node from the pool (if any).
		int sky_idx = pm.getSkyTypeIndex(i);
		Sky *portal_sky = (sky_idx >= 0 && sky_idx < (int)data.sky_pool.size())
				? data.sky_pool[sky_idx] : nullptr;

		video::SColor clear_col = ctx.clear_color;
		if (portal_sky) {
			const PortalSkyType &st = pm.getSkyType(sky_idx);
			if (data.sky) data.sky->setSceneActive(false);
			portal_sky->setSceneActive(true);
			// Use the sky's fog colour as the clear colour so terrain has visible
			// contrast against the background (getSkyColor() gives the upper dome).
			clear_col = st.sunlight_seen
					? portal_sky->getSkyColor()
					: portal_sky->getFogColor();
		}

		// Override driver fog to match the portal's destination sky.
		if (portal_sky) {
			driver->setFog(portal_sky->getFogColor(),
					video::EFT_FOG_LINEAR,
					ctx.fog_range * portal_sky->getFogStart(),
					ctx.fog_range, 0.f, false, ctx.fog_enabled);
		}

		// Ensure clouds are visible when the destination sky has them enabled.
		bool clouds_was_visible = false;
		if (data.clouds_node) {
			clouds_was_visible = data.clouds_node->isVisible();
			if (portal_sky && portal_sky->getCloudsVisible())
				data.clouds_node->setVisible(true);
		}

		driver->setRenderTarget(data.rtex[i],
			video::ECBF_COLOR | video::ECBF_DEPTH,
			clear_col);
		smgr->setActiveCamera(data.vcam[i]);
		// Temporarily show the local player mesh so it appears in portal views.
		// In first-person mode updateMeshCulling() hides it via double-face-culling;
		// that flag is global and would hide the player from portal cameras too.
		GenericCAO *lp_cao = nullptr;
		if (LocalPlayer *lp = ctx.client->getEnv().getLocalPlayer())
			lp_cao = lp->getCAO();
		if (lp_cao)
			lp_cao->setPortalRendering(true);
		// Skip player-camera frustum culling so the virtual camera sees terrain
		// outside the main camera's frustum (ClientMap::renderMap uses game Camera).
		cmap.setBypassFrustumCulling(true);
		smgr->drawAll();
		cmap.setBypassFrustumCulling(false);
		if (lp_cao)
			lp_cao->setPortalRendering(false);

		// Restore clouds visibility to what the main game loop set.
		if (data.clouds_node)
			data.clouds_node->setVisible(clouds_was_visible);

		// Restore fog and sky node after the RTT pass.
		if (portal_sky) {
			if (data.sky)
				driver->setFog(data.sky->getFogColor(),
						video::EFT_FOG_LINEAR,
						ctx.fog_range * data.sky->getFogStart(),
						ctx.fog_range, 0.f, false, ctx.fog_enabled);
			portal_sky->setSceneActive(false);
			if (data.sky) data.sky->setSceneActive(true);
		}

		GL.Disable(GL.CLIP_DISTANCE0);
		GL.Disable(GL.CLIP_DISTANCE1);
		GL.Disable(GL.CLIP_DISTANCE2);
		GL.Disable(GL.CLIP_DISTANCE3);
		{ PortalClipPlanes off; pm.setClipPlanes(off); }

		driver->setRenderTarget(nullptr, 0);
		smgr->setActiveCamera(mainCam);
	}

	// Portal drawlist was only needed for the RTT passes; clear it now so the
	// main render doesn't double-render those blocks.
	cmap.clearPortalDrawList();
}

// Draw portals back-to-front: 5 textured faces per portal with screen-space UV.
// Portals are one-directional: only rendered when the camera is on the front
// (ns) side (d > 0). Depth testing against the world geometry handles occlusion.
static void drawPortalQuads(
	PortalRTTData &data,
	video::IVideoDriver *driver,
	scene::ICameraSceneNode *mainCam)
{
	const PortalManager &pm = PortalManager::get();
	v3f camPos = mainCam->getAbsolutePosition();

	// Collect active portals and sort back-to-front.
	struct SortEntry { float dsq; int idx; };
	SortEntry entries[MAX_PORTALS];
	int nentries = 0;
	for (int i = 0; i < MAX_PORTALS; ++i) {
		if (!data.rtex[i]) continue;
		const PortalInfo &p = pm.portal(i);
		if (!p.active) continue;
		float dsq = (p.pos - data.cam_offset_world - camPos).getLengthSQ();
		entries[nentries++] = {dsq, i};
	}
	std::sort(entries, entries + nentries, [](const SortEntry &a, const SortEntry &b) {
		return a.dsq > b.dsq;
	});

	for (int k = 0; k < nentries; ++k) {
		int i = entries[k].idx;
		PortalInfo src = pm.portal(i);
		src.pos -= data.cam_offset_world;

		float d = (camPos - src.pos).dotProduct(src.normal);
		float dist = (camPos - src.pos).getLength();
		// For horizontal portals (floor/ceiling) src.pos is at the block centre
		// which is 0.5·BS below the portal surface.  d=0 is 50% into the frame;
		// allow the camera to reach 90% (d = surface_offset - 0.9 * frame = -0.4·BS).
		float d_min = (std::abs(src.normal.Y) > 0.5f) ? -0.4f * BS : 0.0f;
		if (d <= d_min || dist < 0.001f * BS || (d > 0.0f && d / dist < 0.1f))
			continue;

		drawPortalFaces(driver, src, 1.0f, data.rtex[i], mainCam);
	}
}

// -----------------------------------------------------------------------
// PortalPrepareStep — runs BEFORE Draw3D in the post-processing pipeline
// -----------------------------------------------------------------------

void PortalPrepareStep::run(PipelineContext &ctx)
{
	const PortalManager &pm = PortalManager::get();
	if (!pm.anyActive())
		return;

	auto *smgr    = ctx.device->getSceneManager();
	auto *mainCam = smgr->getActiveCamera();
	if (!mainCam)
		return;

	m_data->main_cam = mainCam;
	m_data->sky = ctx.sky;
	m_data->sky_pool = ctx.sky_pool;
	m_data->clouds_node = ctx.clouds_node;
	mainCam->updateAbsolutePosition();
	renderPortalRTTs(*m_data, ctx, mainCam);
	// Render target is now at FBO=0/screen. Draw3D's m_target->activate() will
	// correctly re-bind the TextureBuffer FBO via Irrlicht's cache handler.
}

// -----------------------------------------------------------------------
// PortalQuadStep — runs AFTER Draw3D, BEFORE post-processing
// -----------------------------------------------------------------------

void PortalQuadStep::run(PipelineContext &ctx)
{
	const PortalManager &pm = PortalManager::get();
	if (!pm.anyActive() || !m_data->main_cam)
		return;

	auto *driver  = ctx.device->getVideoDriver();
	auto *mainCam = m_data->main_cam;

	// Refresh cached absolute position — it may have changed since PortalPrepareStep
	// if the player teleported intra-frame (camera node moved between the two steps).
	mainCam->updateAbsolutePosition();
	v3f camPos = mainCam->getAbsolutePosition();

	// If the camera jumped ≥ 4 nodes since RTTs were rendered, re-render now so
	// the portal texture shows the new view rather than a one-frame stale image.
	if (m_data->rtt_cam_valid) {
		float jump_sq = (camPos - m_data->rtt_cam_pos).getLengthSQ();
		if (jump_sq > (4.0f * BS) * (4.0f * BS)) {
			renderPortalRTTs(*m_data, ctx, mainCam);
			// renderPortalRTTs leaves render target at FBO=0/screen; restore the
			// scene render target (TextureBuffer in PP mode) so portal quads go
			// into the correct buffer.
			if (m_data->scene_rt)
				m_data->scene_rt->activate(ctx);
		}
	}

	// Render target is still the TextureBuffer (set by Draw3D, or just restored).
	drawPortalQuads(*m_data, driver, mainCam);
}

// -----------------------------------------------------------------------
// PortalRenderStep — combined step for the non-post-processing pipeline
// -----------------------------------------------------------------------

PortalRenderStep::~PortalRenderStep()
{
	// m_data destructor handles vcam cleanup.
}

void PortalRenderStep::run(PipelineContext &ctx)
{
	const PortalManager &pm = PortalManager::get();
	if (!pm.anyActive())
		return;

	auto *driver  = ctx.device->getVideoDriver();
	auto *smgr    = ctx.device->getSceneManager();
	auto *mainCam = smgr->getActiveCamera();
	if (!mainCam)
		return;

	m_data.sky = ctx.sky;
	m_data.sky_pool = ctx.sky_pool;
	m_data.clouds_node = ctx.clouds_node;
	// Render RTTs. Leaves render target at FBO=0 (screen) — correct for non-PP.
	renderPortalRTTs(m_data, ctx, mainCam);

	// Draw portal quads directly to the screen (FBO=0, no post-processing to worry about).
	drawPortalQuads(m_data, driver, mainCam);
}
