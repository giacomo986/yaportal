// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once

#include "irr_v3d.h"

static constexpr int MAX_PORTALS = 8;

struct PortalInfo {
	v3f pos;      // world-space center (BS scale)
	v3f normal;   // outward-facing unit normal
	v3f up;       // up direction unit vector
	float half_w = 0.0f;  // half-width in world units (BS scale)
	float half_h = 0.0f;  // half-height in world units (BS scale)
	int link = -1;         // index of linked portal (-1 = no link / no RTT)
	bool active = false;
};

// Lateral clip planes for one RTT pass: 4 planes that bound the exit portal
// opening (right/left/top/bottom). gl_ClipDistance[k] = dot(worldPos, n) + d.
// active=false when not in an RTT pass; the shader still writes gl_ClipDistance
// but GL_CLIP_DISTANCEn is disabled so the values are ignored.
struct PortalClipPlanes {
	bool  active = false;
	float data[16] = {}; // [k*4+0..2]=normal, [k*4+3]=d, for k=0..3
};

// Non-thread-safe singleton. Access only from the main thread.
class PortalManager {
public:
	static PortalManager &get();

	void setPortal(int id, v3f pos, v3f normal, v3f up, float half_w, float half_h, int link);
	void clearPortal(int id);
	void clearAll();

	const PortalInfo &portal(int id) const { return m_portals[id]; }
	bool anyActive() const;

	// Camera position override for portal `id` RTT rendering.
	// Lua sets this every frame while the player is inside the portal frame.
	// Hint persists (non-consuming) until clearCamHint is called so it
	// remains valid across multiple render frames between server ticks.
	void setCamHint(int id, v3f world_pos_bs);
	// Read the hint without consuming it. Returns false when none is set.
	bool getCamHint(int id, v3f &out_world_pos_bs) const;
	// Lua calls this when the player leaves the source portal bounds.
	void clearCamHint(int id);

	// Active lateral clip planes for the current RTT pass.
	void setClipPlanes(const PortalClipPlanes &cp) { m_clip_planes = cp; }
	const PortalClipPlanes &getClipPlanes() const  { return m_clip_planes; }

private:
	PortalInfo m_portals[MAX_PORTALS];
	struct CamHintSlot { v3f pos = {}; bool valid = false; };
	CamHintSlot m_cam_hint[MAX_PORTALS];
	PortalClipPlanes m_clip_planes;
};
