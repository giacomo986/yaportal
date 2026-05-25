// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
#include "portal_manager.h"
#include <cassert>

PortalManager &PortalManager::get()
{
	static PortalManager instance;
	return instance;
}

void PortalManager::setPortal(int id, v3f pos, v3f normal, v3f up,
		float half_w, float half_h, int link)
{
	assert(id >= 0 && id < MAX_PORTALS);
	m_portals[id] = {pos, normal, up, half_w, half_h, link, true};
}

void PortalManager::clearPortal(int id)
{
	assert(id >= 0 && id < MAX_PORTALS);
	m_portals[id].active = false;
	m_cam_hint[id].valid = false;
}

void PortalManager::clearAll()
{
	for (auto &p : m_portals) p.active = false;
	for (auto &h : m_cam_hint) h.valid = false;
}

bool PortalManager::anyActive() const
{
	for (const auto &p : m_portals)
		if (p.active) return true;
	return false;
}

void PortalManager::setCamHint(int id, v3f world_pos_bs)
{
	assert(id >= 0 && id < MAX_PORTALS);
	m_cam_hint[id] = {world_pos_bs, true};
}

bool PortalManager::getCamHint(int id, v3f &out_world_pos_bs) const
{
	assert(id >= 0 && id < MAX_PORTALS);
	const CamHintSlot &s = m_cam_hint[id];
	if (!s.valid)
		return false;
	out_world_pos_bs = s.pos;
	return true;
}

void PortalManager::clearCamHint(int id)
{
	assert(id >= 0 && id < MAX_PORTALS);
	m_cam_hint[id].valid = false;
}

void PortalManager::setSkyConfig(int id, PortalSkySlot::SkyMode mode, u32 clear_color_argb)
{
	assert(id >= 0 && id < MAX_PORTALS);
	m_sky_config[id].mode = mode;
	m_sky_config[id].clear_color_argb = clear_color_argb;
}

void PortalManager::clearSkyConfig(int id)
{
	assert(id >= 0 && id < MAX_PORTALS);
	m_sky_config[id] = {};
}
