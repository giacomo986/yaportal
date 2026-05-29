// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
#include "portal_manager.h"
#include <cassert>
#include <algorithm>

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

int PortalManager::registerSkyType(const std::string &name, const PortalSkyType &type)
{
	auto it = std::find(m_sky_type_names.begin(), m_sky_type_names.end(), name);
	if (it != m_sky_type_names.end())
		return (int)(it - m_sky_type_names.begin());
	m_sky_type_names.push_back(name);
	m_sky_types.push_back(type);
	m_sky_types.back().dirty = true;
	return (int)m_sky_types.size() - 1;
}

void PortalManager::updateSkyType(int index, const PortalSkyType &type)
{
	assert(index >= 0 && index < (int)m_sky_types.size());
	m_sky_types[index] = type;
	m_sky_types[index].dirty = true;
}

void PortalManager::setSkySlot(int portal_id, int sky_type_index)
{
	assert(portal_id >= 0 && portal_id < MAX_PORTALS);
	m_sky_slots[portal_id].sky_type_index = sky_type_index;
}

void PortalManager::clearSkySlot(int portal_id)
{
	assert(portal_id >= 0 && portal_id < MAX_PORTALS);
	m_sky_slots[portal_id].sky_type_index = -1;
}
