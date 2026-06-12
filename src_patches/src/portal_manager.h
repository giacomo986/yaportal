// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once

#include "irr_v3d.h"
#include "skyparams.h"
#include <string>
#include <vector>

static constexpr int MAX_PORTALS = 16;

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
	float data[20] = {}; // [k*4+0..2]=normal, [k*4+3]=d, for k=0..3 (lateral frustum); k=4: portal surface near clip
};

// Full description of a sky type for portal RTT rendering.
// Multiple portals share one sky type when pointing to the same dimension.
// The Sky node instance for this type lives in game.cpp's m_portal_sky_pool.
struct PortalSkyType {
	SkyboxParams sky_params;              // full set_sky parameters for this dimension
	bool  sunlight_seen          = false; // passed to Sky::update() sunlight_seen arg
	float direct_brightness_scale = 0.0f; // 1.0 = time_brightness, 0.0 = always dark
	bool  dirty                  = true;  // true → game.cpp must call applySkyParams()
};

// Per-portal sky slot: which sky type index to use for this portal's RTT.
// sky_type_index == -1 → DEFAULT (main player sky, no swap).
struct PortalSkySlot {
	int sky_type_index = -1;
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
	void setCamHint(int id, v3f world_pos_bs);
	bool getCamHint(int id, v3f &out_world_pos_bs) const;
	void clearCamHint(int id);

	// Sky type pool — one entry per distinct dimension sky.
	// registerSkyType: dedup by name (same name → returns existing index).
	// updateSkyType: replace params and mark dirty.
	int  registerSkyType(const std::string &name, const PortalSkyType &type);
	void updateSkyType(int index, const PortalSkyType &type);
	int  skyTypeCount() const { return (int)m_sky_types.size(); }
	const PortalSkyType &getSkyType(int index) const { return m_sky_types[index]; }
	bool isSkyTypeDirty(int index) const { return m_sky_types[index].dirty; }
	void clearSkyTypeDirty(int index) { m_sky_types[index].dirty = false; }

	// Per-portal sky slot assignment.
	void setSkySlot(int portal_id, int sky_type_index);
	void clearSkySlot(int portal_id);
	int  getSkyTypeIndex(int portal_id) const { return m_sky_slots[portal_id].sky_type_index; }

	// Active lateral clip planes for the current RTT pass.
	void setClipPlanes(const PortalClipPlanes &cp) { m_clip_planes = cp; }
	const PortalClipPlanes &getClipPlanes() const  { return m_clip_planes; }

private:
	PortalInfo m_portals[MAX_PORTALS];
	struct CamHintSlot { v3f pos = {}; bool valid = false; };
	CamHintSlot  m_cam_hint[MAX_PORTALS];
	PortalSkySlot m_sky_slots[MAX_PORTALS];
	std::vector<PortalSkyType> m_sky_types;
	std::vector<std::string>   m_sky_type_names;
	PortalClipPlanes m_clip_planes;
};
