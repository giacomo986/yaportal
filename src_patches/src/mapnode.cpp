// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#include "irrlichttypes_bloated.h"
#include "mapnode.h"
#include "nodedef.h"
#include "itemgroup.h"
#include "map.h"
#include "content_mapnode.h" // For mapnode_translate_*_internal
#include "serialization.h" // For ser_ver_supported_*
#include "util/serialize.h"
#include "util/directiontables.h"
#include <string>

static const Rotation wallmounted_to_rot[] = {
	ROTATE_0, ROTATE_180, ROTATE_90, ROTATE_270
};

static const u8 rot_to_wallmounted[] = {
	2, 4, 3, 5
};


/*
	MapNode
*/

u8 MapNode::getFaceDir(const NodeDefManager *nodemgr,
	bool allow_wallmounted) const
{
	const ContentFeatures &f = nodemgr->get(*this);
	if (f.param_type_2 == CPT2_FACEDIR ||
			f.param_type_2 == CPT2_COLORED_FACEDIR)
		return (getParam2() & 0x1F) % 24;
	if (f.param_type_2 == CPT2_4DIR ||
			f.param_type_2 == CPT2_COLORED_4DIR)
		return getParam2() & 0x03;
	if (allow_wallmounted && (f.param_type_2 == CPT2_WALLMOUNTED ||
			f.param_type_2 == CPT2_COLORED_WALLMOUNTED)) {
		u8 wmountface = MYMIN(getParam2() & 0x07, DWM_COUNT - 1);
		return wallmounted_to_facedir[wmountface];
	}
	return 0;
}

u8 MapNode::getWallMounted(const NodeDefManager *nodemgr) const
{
	const ContentFeatures &f = nodemgr->get(*this);
	if (f.param_type_2 == CPT2_WALLMOUNTED ||
			f.param_type_2 == CPT2_COLORED_WALLMOUNTED)
		return MYMIN(getParam2() & 0x07, DWM_COUNT - 1);
	else if (f.drawtype == NDT_SIGNLIKE || f.drawtype == NDT_TORCHLIKE ||
			f.drawtype == NDT_PLANTLIKE ||
			f.drawtype == NDT_PLANTLIKE_ROOTED) {
		return 1;
	}
	return 0;
}

v3s16 MapNode::getWallMountedDir(const NodeDefManager *nodemgr) const
{
	switch(getWallMounted(nodemgr))
	{
	case 0: default: return v3s16(0,1,0);
	case 1: return v3s16(0,-1,0);
	case 2: return v3s16(1,0,0);
	case 3: return v3s16(-1,0,0);
	case 4: return v3s16(0,0,1);
	case 5: return v3s16(0,0,-1);
	case 6: return v3s16(0,1,0);
	case 7: return v3s16(0,-1,0);
	}
}

u8 MapNode::getDegRotate(const NodeDefManager *nodemgr) const
{
	const ContentFeatures &f = nodemgr->get(*this);
	if (f.param_type_2 == CPT2_DEGROTATE)
		return getParam2() % 240;
	if (f.param_type_2 == CPT2_COLORED_DEGROTATE)
		return 10 * ((getParam2() & 0x1F) % 24);
	return 0;
}

void MapNode::rotateAlongYAxis(const NodeDefManager *nodemgr, Rotation rot)
{
	ContentParamType2 cpt2 = nodemgr->get(*this).param_type_2;

	if (cpt2 == CPT2_FACEDIR || cpt2 == CPT2_COLORED_FACEDIR ||
			cpt2 == CPT2_4DIR || cpt2 == CPT2_COLORED_4DIR) {
		static const u8 rotate_facedir[24 * 4] = {
			// Table value = rotated facedir
			// Columns: 0, 90, 180, 270 degrees rotation around vertical axis
			// Rotation is anticlockwise as seen from above (+Y)

			0, 1, 2, 3,  // Initial facedir 0 to 3
			1, 2, 3, 0,
			2, 3, 0, 1,
			3, 0, 1, 2,

			4, 13, 10, 19,  // 4 to 7
			5, 14, 11, 16,
			6, 15, 8, 17,
			7, 12, 9, 18,

			8, 17, 6, 15,  // 8 to 11
			9, 18, 7, 12,
			10, 19, 4, 13,
			11, 16, 5, 14,

			12, 9, 18, 7,  // 12 to 15
			13, 10, 19, 4,
			14, 11, 16, 5,
			15, 8, 17, 6,

			16, 5, 14, 11,  // 16 to 19
			17, 6, 15, 8,
			18, 7, 12, 9,
			19, 4, 13, 10,

			20, 23, 22, 21,  // 20 to 23
			21, 20, 23, 22,
			22, 21, 20, 23,
			23, 22, 21, 20
		};
		if (cpt2 == CPT2_FACEDIR || cpt2 == CPT2_COLORED_FACEDIR) {
			u8 facedir = (param2 & 31) % 24;
			u8 index = facedir * 4 + rot;
			param2 &= ~31;
			param2 |= rotate_facedir[index];
		} else if (cpt2 == CPT2_4DIR || cpt2 == CPT2_COLORED_4DIR) {
			u8 fourdir = param2 & 3;
			u8 index = fourdir * 4 + rot;
			param2 &= ~3;
			param2 |= rotate_facedir[index];
		}
	} else if (cpt2 == CPT2_WALLMOUNTED ||
			cpt2 == CPT2_COLORED_WALLMOUNTED) {
		u8 wmountface = MYMIN(param2 & 0x07, DWM_COUNT - 1);
		if (wmountface <= 1)
			return;

		Rotation oldrot = wallmounted_to_rot[wmountface - 2];
		param2 &= ~7;
		param2 |= rot_to_wallmounted[(oldrot - rot) & 3];
	} else if (cpt2 == CPT2_DEGROTATE) {
		int angle = param2; // in 1.5°
		angle += 60 * rot; // don’t do that on u8
		angle %= 240;
		param2 = angle;
	} else if (cpt2 == CPT2_COLORED_DEGROTATE) {
		int angle = param2 & 0x1F; // in 15°
		int color = param2 & 0xE0;
		angle += 6 * rot;
		angle %= 24;
		param2 = color | angle;
	}
}

void transformNodeBox(const MapNode &n, const NodeBox &nodebox,
	const NodeDefManager *nodemgr, std::vector<aabb3f> *p_boxes,
	u8 neighbors = 0)
{
	std::vector<aabb3f> &boxes = *p_boxes;

	if (nodebox.type == NODEBOX_FIXED || nodebox.type == NODEBOX_LEVELED) {
		const auto &fixed = nodebox.fixed;
		int facedir = n.getFaceDir(nodemgr, true);
		u8 axisdir = facedir >> 2;
		facedir &= 0x03;

		boxes.reserve(boxes.size() + fixed.size());
		for (aabb3f box : fixed) {
			if (nodebox.type == NODEBOX_LEVELED)
				box.MaxEdge.Y = (-0.5f + n.getLevel(nodemgr) / 64.0f) * BS;

			if(facedir == 1) {
				box.MinEdge.rotateXZBy(-90);
				box.MaxEdge.rotateXZBy(-90);
			} else if(facedir == 2) {
				box.MinEdge.rotateXZBy(180);
				box.MaxEdge.rotateXZBy(180);
			} else if(facedir == 3) {
				box.MinEdge.rotateXZBy(90);
				box.MaxEdge.rotateXZBy(90);
			}

			switch (axisdir) {
			case 0:
				break;
			case 1: // z+
				box.MinEdge.rotateYZBy(90);
				box.MaxEdge.rotateYZBy(90);
				break;
			case 2: //z-
				box.MinEdge.rotateYZBy(-90);
				box.MaxEdge.rotateYZBy(-90);
				break;
			case 3:  //x+
				box.MinEdge.rotateXYBy(-90);
				box.MaxEdge.rotateXYBy(-90);
				break;
			case 4:  //x-
				box.MinEdge.rotateXYBy(90);
				box.MaxEdge.rotateXYBy(90);
				break;
			case 5:
				box.MinEdge.rotateXYBy(-180);
				box.MaxEdge.rotateXYBy(-180);
				break;
			default:
				break;
			}

			box.repair();
			boxes.push_back(box);
		}
	}
	else if(nodebox.type == NODEBOX_WALLMOUNTED)
	{
		v3s16 dir = n.getWallMountedDir(nodemgr);
		u8 wall = n.getWallMounted(nodemgr);

		// top
		if(dir == v3s16(0,1,0))
		{
			if (wall == DWM_S1) {
				v3f vertices[2] =
				{
					nodebox.wall_top.MinEdge,
					nodebox.wall_top.MaxEdge
				};
				for (v3f &vertex : vertices) {
					vertex.rotateXZBy(90);
				}
				aabb3f box = aabb3f(vertices[0]);
				box.addInternalPoint(vertices[1]);
				boxes.push_back(box);
			} else {
				boxes.push_back(nodebox.wall_top);
			}
		}
		// bottom
		else if(dir == v3s16(0,-1,0))
		{
			if (wall == DWM_S2) {
				v3f vertices[2] =
				{
					nodebox.wall_bottom.MinEdge,
					nodebox.wall_bottom.MaxEdge
				};
				for (v3f &vertex : vertices) {
					vertex.rotateXZBy(-90);
				}
				aabb3f box = aabb3f(vertices[0]);
				box.addInternalPoint(vertices[1]);
				boxes.push_back(box);
			} else {
				boxes.push_back(nodebox.wall_bottom);
			}
		}
		// side
		else
		{
			v3f vertices[2] =
			{
				nodebox.wall_side.MinEdge,
				nodebox.wall_side.MaxEdge
			};

			for (v3f &vertex : vertices) {
				if(dir == v3s16(-1,0,0))
					vertex.rotateXZBy(0);
				if(dir == v3s16(1,0,0))
					vertex.rotateXZBy(180);
				if(dir == v3s16(0,0,-1))
					vertex.rotateXZBy(90);
				if(dir == v3s16(0,0,1))
					vertex.rotateXZBy(-90);
			}

			aabb3f box = aabb3f(vertices[0]);
			box.addInternalPoint(vertices[1]);
			boxes.push_back(box);
		}
	}
	else if (nodebox.type == NODEBOX_CONNECTED)
	{
		size_t boxes_size = boxes.size();
		boxes_size += nodebox.fixed.size();
		const auto &c = nodebox.getConnected();

		if (neighbors & 1)
			boxes_size += c.connect_top.size();
		else
			boxes_size += c.disconnected_top.size();

		if (neighbors & 2)
			boxes_size += c.connect_bottom.size();
		else
			boxes_size += c.disconnected_bottom.size();

		if (neighbors & 4)
			boxes_size += c.connect_front.size();
		else
			boxes_size += c.disconnected_front.size();

		if (neighbors & 8)
			boxes_size += c.connect_left.size();
		else
			boxes_size += c.disconnected_left.size();

		if (neighbors & 16)
			boxes_size += c.connect_back.size();
		else
			boxes_size += c.disconnected_back.size();

		if (neighbors & 32)
			boxes_size += c.connect_right.size();
		else
			boxes_size += c.disconnected_right.size();

		if (neighbors == 0)
			boxes_size += c.disconnected.size();

		if (neighbors < 4)
			boxes_size += c.disconnected_sides.size();

		boxes.reserve(boxes_size);

		auto boxes_insert = [&](const std::vector<aabb3f> &boxes_src) {
			boxes.insert(boxes.end(), boxes_src.begin(), boxes_src.end());
		};

		boxes_insert(nodebox.fixed);

		if (neighbors & 1)
			boxes_insert(c.connect_top);
		else
			boxes_insert(c.disconnected_top);

		if (neighbors & 2)
			boxes_insert(c.connect_bottom);
		else
			boxes_insert(c.disconnected_bottom);

		if (neighbors & 4)
			boxes_insert(c.connect_front);
		else
			boxes_insert(c.disconnected_front);

		if (neighbors & 8)
			boxes_insert(c.connect_left);
		else
			boxes_insert(c.disconnected_left);

		if (neighbors & 16)
			boxes_insert(c.connect_back);
		else
			boxes_insert(c.disconnected_back);

		if (neighbors & 32)
			boxes_insert(c.connect_right);
		else
			boxes_insert(c.disconnected_right);

		if (neighbors == 0)
			boxes_insert(c.disconnected);

		if (neighbors < 4)
			boxes_insert(c.disconnected_sides);

	}
	else // NODEBOX_REGULAR
	{
		boxes.emplace_back(-BS/2,-BS/2,-BS/2,BS/2,BS/2,BS/2);
	}
}

static inline void getNeighborConnectingFace(
	const v3s16 &p, const NodeDefManager *nodedef,
	Map *map, MapNode n, u8 bitmask, u8 *neighbors)
{
	MapNode n2 = map->getNode(p);
	if (nodedef->nodeboxConnects(n, n2, bitmask))
		*neighbors |= bitmask;
}

// ── yaportal: portal_block (type-2 hollow portal blocks) ─────────────────────
// Face index order matches drawCuboid / nodebox_tile_dirs:
//   0=+Y 1=-Y 2=+X 3=-X 4=+Z 5=-Z. Opposite face = index ^ 1.
// A face is "open" (no wall, passable, not drawn) when it is the front face
// (the portal, taken from the wallmounted param2) or when it is an in-plane
// face touching another portal_block with the same param2 (so adjacent blocks
// merge into one continuous cavity). Front always open, back always solid.
static const v3s16 portal_block_face_dirs[6] = {
	v3s16(0, 1, 0), v3s16(0, -1, 0), v3s16(1, 0, 0),
	v3s16(-1, 0, 0), v3s16(0, 0, 1), v3s16(0, 0, -1),
};

static inline int portal_block_dir_to_face(v3s16 d)
{
	for (int i = 0; i < 6; i++)
		if (portal_block_face_dirs[i] == d)
			return i;
	return 5;
}

static inline bool is_portal_block(const ContentFeatures &f)
{
	return itemgroup_get(f.groups, "portal_block") != 0;
}

// yaportal slab shell descriptor (group portal_slab = 1..6): the cell's solid
// material fills only half of the cell — the half whose OUTER face index
// (order 0=+Y 1=-Y 2=+X 3=-X 4=+Z 5=-Z) is the group value minus one. Shell
// panels and carve geometry are confined to those bounds so a carved panel
// slab keeps its slab silhouette instead of bulging to a full cube.
static void portal_block_material_bounds(const ContentFeatures &f,
	float mlo[3], float mhi[3])
{
	const float H = 0.5f * BS;
	mlo[0] = mlo[1] = mlo[2] = -H;
	mhi[0] = mhi[1] = mhi[2] = H;
	const int ps = itemgroup_get(f.groups, "portal_slab");
	if (ps < 1 || ps > 6)
		return;
	const int face = ps - 1;
	const int axis = (face < 2) ? 1 : (face < 4 ? 0 : 2);
	if (face % 2 == 0)
		mlo[axis] = 0.0f;   // occupies the + half
	else
		mhi[axis] = 0.0f;   // occupies the - half
}

// yaportal partial-carve descriptor, stored in the param2 bits above the
// wallmounted direction (getWallMounted masks & 0x07, so bits 3..6 are free):
//   carve = (param2 >> 3) & 0x0F
//   0      = front face fully open (classic portal block)
//   1..4   = only HALF of the front face is open, split along one of the two
//            in-plane world axes (taken in ascending X<Y<Z order):
//            1 = first axis, open on the - half   2 = first axis, open on +
//            3 = second axis, open on the - half  4 = second axis, open on +
//   5..8   = only a QUARTER is open (portal offset on both in-plane axes):
//            5 + (first axis open on + ? 1 : 0) + (second axis open on + ? 2 : 0)
// Used by yaportal for portals offset half a node from the grid: the edge
// blocks are partially carved and get partial front panels plus partition
// walls separating the cavity from the solid (dead) parts.
static inline int portal_block_carve(const MapNode &n)
{
	return (n.getParam2() >> 3) & 0x0F;
}

// Decode a carve value into up to two cuts. Each cut says: on `axis`, the
// open part of the front face is the `open_pos` half. Returns cut count.
static int portal_block_carve_cuts(int carve, int a0, int a1,
	int axes[2], bool open_pos[2])
{
	if (carve >= 1 && carve <= 4) {
		axes[0] = (carve <= 2) ? a0 : a1;
		open_pos[0] = (carve == 2 || carve == 4);
		return 1;
	}
	if (carve >= 5 && carve <= 8) {
		axes[0] = a0; open_pos[0] = ((carve - 5) & 1) != 0;
		axes[1] = a1; open_pos[1] = ((carve - 5) & 2) != 0;
		return 2;
	}
	return 0;
}

// The two in-plane world axes (0=X,1=Y,2=Z) of a face, ascending.
static inline void portal_face_inplane_axes(int face, int *a0, int *a1)
{
	int naxis = (face < 2) ? 1 : (face < 4 ? 0 : 2);
	if (naxis == 0)      { *a0 = 1; *a1 = 2; }
	else if (naxis == 1) { *a0 = 0; *a1 = 2; }
	else                 { *a0 = 0; *a1 = 1; }
}

static inline void portal_box_set_axis(aabb3f &b, int axis, float lo, float hi)
{
	switch (axis) {
	case 0: b.MinEdge.X = lo; b.MaxEdge.X = hi; break;
	case 1: b.MinEdge.Y = lo; b.MaxEdge.Y = hi; break;
	default: b.MinEdge.Z = lo; b.MaxEdge.Z = hi; break;
	}
}

// Outer wall panel (thin) on the given face, confined to the material bounds
// (the full cell, or the slab half). Kept thin so a stacked W×H portal leaves
// enough clear interior to walk through: vertical clearance = h - 2t must
// exceed the player height (~1.8), so 2t must stay < 0.2.
static aabb3f portal_block_panel(int face, const float mlo[3], const float mhi[3])
{
	const float t = (1.0f / 32.0f) * BS;
	aabb3f b(mlo[0], mlo[1], mlo[2], mhi[0], mhi[1], mhi[2]);
	const int axis = (face < 2) ? 1 : (face < 4 ? 0 : 2);
	if (face % 2 == 0)
		portal_box_set_axis(b, axis, mhi[axis] - t, mhi[axis]);
	else
		portal_box_set_axis(b, axis, mlo[axis], mlo[axis] + t);
	return b;
}

// Clamp a box to the material bounds; false when nothing is left.
static bool portal_box_clamp(aabb3f &b, const float mlo[3], const float mhi[3])
{
	b.MinEdge.X = std::max(b.MinEdge.X, mlo[0]);
	b.MinEdge.Y = std::max(b.MinEdge.Y, mlo[1]);
	b.MinEdge.Z = std::max(b.MinEdge.Z, mlo[2]);
	b.MaxEdge.X = std::min(b.MaxEdge.X, mhi[0]);
	b.MaxEdge.Y = std::min(b.MaxEdge.Y, mhi[1]);
	b.MaxEdge.Z = std::min(b.MaxEdge.Z, mhi[2]);
	return b.MinEdge.X < b.MaxEdge.X && b.MinEdge.Y < b.MaxEdge.Y &&
			b.MinEdge.Z < b.MaxEdge.Z;
}

// Bitmask (1<<face) of the open faces of a portal_block. `neighbors` carries the
// in-plane same-param2 neighbor bits computed by getNeighbors().
static u8 portal_block_open_faces(const MapNode &n, const NodeDefManager *nodemgr,
	u8 neighbors)
{
	// Closed (unlinked) portal block: fully solid, no passable/open faces.
	if (itemgroup_get(nodemgr->get(n).groups, "portal_closed") != 0)
		return 0;
	int front = portal_block_dir_to_face(n.getWallMountedDir(nodemgr));
	int back = front ^ 1;
	u8 open = (u8)(1 << front);
	for (int f = 0; f < 6; f++) {
		if (f == front || f == back)
			continue;
		if (neighbors & (1 << f))
			open |= (u8)(1 << f);
	}
	return open;
}

// Shared collision/selection box builder for portal_block nodes: one thin
// panel per solid face, plus — for half-carved blocks — a partial front panel
// over the closed half and a partition wall between cavity and dead half.
// Everything is confined to the material bounds (slab shells, see
// portal_block_material_bounds); boxes that end up empty are dropped.
static void portal_block_push_boxes(const MapNode &n, const NodeDefManager *nodemgr,
	u8 neighbors, std::vector<aabb3f> *boxes)
{
	float mlo[3], mhi[3];
	portal_block_material_bounds(nodemgr->get(n), mlo, mhi);
	u8 open = portal_block_open_faces(n, nodemgr, neighbors);
	for (int face = 0; face < 6; face++)
		if (!(open & (1 << face)))
			boxes->push_back(portal_block_panel(face, mlo, mhi));

	int carve = portal_block_carve(n);
	if (open == 0 || carve < 1 || carve > 8)
		return;
	int front = portal_block_dir_to_face(n.getWallMountedDir(nodemgr));
	if (!(open & (1 << front)))
		return;
	int a0, a1;
	portal_face_inplane_axes(front, &a0, &a1);
	int axes[2];
	bool open_pos[2];
	const int ncuts = portal_block_carve_cuts(carve, a0, a1, axes, open_pos);
	const float H = 0.5f * BS;
	const float t = (1.0f / 32.0f) * BS;
	for (int i = 0; i < ncuts; i++) {
		// Front panel over the closed part of the face along this cut; later
		// panels are clipped to the open range of earlier cuts so quarter
		// carves get a non-overlapping L shape.
		aabb3f fp = portal_block_panel(front, mlo, mhi);
		if (open_pos[i])
			portal_box_set_axis(fp, axes[i], -H, 0.0f);
		else
			portal_box_set_axis(fp, axes[i], 0.0f, H);
		for (int j = 0; j < i; j++) {
			if (open_pos[j])
				portal_box_set_axis(fp, axes[j], 0.0f, H);
			else
				portal_box_set_axis(fp, axes[j], -H, 0.0f);
		}
		if (portal_box_clamp(fp, mlo, mhi))
			boxes->push_back(fp);
		// Partition wall at the half plane, flush against the cavity on the
		// dead side (cavity floor/ceiling/side wall).
		aabb3f part(-H, -H, -H, H, H, H);
		if (open_pos[i])
			portal_box_set_axis(part, axes[i], -t, 0.0f);
		else
			portal_box_set_axis(part, axes[i], 0.0f, t);
		if (portal_box_clamp(part, mlo, mhi))
			boxes->push_back(part);
	}
}

u8 MapNode::getNeighbors(v3s16 p, Map *map) const
{
	const NodeDefManager *nodedef = map->getNodeDefManager();
	u8 neighbors = 0;
	const ContentFeatures &f = nodedef->get(*this);
	// locate possible neighboring nodes to connect to
	if (is_portal_block(f)) {
		int front = portal_block_dir_to_face(this->getWallMountedDir(nodedef));
		int back = front ^ 1;
		// One portal's cells may be different node ids (shell-material
		// variants), so merging keys on the portal_block group VALUE (one
		// value per portal colour) plus the wallmounted direction bits;
		// carve bits (3..6) may differ between edge and middle blocks.
		const int my_pb = itemgroup_get(f.groups, "portal_block");
		for (int face = 0; face < 6; face++) {
			if (face == front || face == back)
				continue;
			MapNode n2 = map->getNode(p + portal_block_face_dirs[face]);
			if (itemgroup_get(nodedef->get(n2).groups, "portal_block") == my_pb &&
					(n2.getParam2() & 0x07) == (this->getParam2() & 0x07))
				neighbors |= (u8)(1 << face);
		}
	} else if (f.drawtype == NDT_NODEBOX && f.node_box.type == NODEBOX_CONNECTED) {
		v3s16 p2 = p;

		p2.Y++;
		getNeighborConnectingFace(p2, nodedef, map, *this, 1, &neighbors);

		p2 = p;
		p2.Y--;
		getNeighborConnectingFace(p2, nodedef, map, *this, 2, &neighbors);

		p2 = p;
		p2.Z--;
		getNeighborConnectingFace(p2, nodedef, map, *this, 4, &neighbors);

		p2 = p;
		p2.X--;
		getNeighborConnectingFace(p2, nodedef, map, *this, 8, &neighbors);

		p2 = p;
		p2.Z++;
		getNeighborConnectingFace(p2, nodedef, map, *this, 16, &neighbors);

		p2 = p;
		p2.X++;
		getNeighborConnectingFace(p2, nodedef, map, *this, 32, &neighbors);
	}

	return neighbors;
}

void MapNode::getNodeBoxes(const NodeDefManager *nodemgr,
	std::vector<aabb3f> *boxes, u8 neighbors) const
{
	const ContentFeatures &f = nodemgr->get(*this);
	transformNodeBox(*this, f.node_box, nodemgr, boxes, neighbors);
}

void MapNode::getCollisionBoxes(const NodeDefManager *nodemgr,
	std::vector<aabb3f> *boxes, u8 neighbors) const
{
	const ContentFeatures &f = nodemgr->get(*this);
	if (is_portal_block(f)) {
		portal_block_push_boxes(*this, nodemgr, neighbors, boxes);
		return;
	}
	if (f.collision_box.fixed.empty())
		transformNodeBox(*this, f.node_box, nodemgr, boxes, neighbors);
	else
		transformNodeBox(*this, f.collision_box, nodemgr, boxes, neighbors);
}

void MapNode::getSelectionBoxes(const NodeDefManager *nodemgr,
	std::vector<aabb3f> *boxes, u8 neighbors) const
{
	const ContentFeatures &f = nodemgr->get(*this);
	if (is_portal_block(f)) {
		// Selection box mirrors the actual collision panels so the pointed-node
		// wireframe shows exactly which faces (or half-faces) are solid.
		portal_block_push_boxes(*this, nodemgr, neighbors, boxes);
		return;
	}
	transformNodeBox(*this, f.selection_box, nodemgr, boxes, neighbors);
}

u8 MapNode::getMaxLevel(const NodeDefManager *nodemgr) const
{
	const ContentFeatures &f = nodemgr->get(*this);
	// todo: after update in all games leave only if (f.param_type_2 ==
	if( f.liquid_type == LIQUID_FLOWING || f.param_type_2 == CPT2_FLOWINGLIQUID)
		return LIQUID_LEVEL_MAX;
	if(f.leveled || f.param_type_2 == CPT2_LEVELED)
		return f.leveled_max;
	return 0;
}

u8 MapNode::getLevel(const NodeDefManager *nodemgr) const
{
	const ContentFeatures &f = nodemgr->get(*this);
	// todo: after update in all games leave only if (f.param_type_2 ==
	if(f.liquid_type == LIQUID_SOURCE)
		return LIQUID_LEVEL_SOURCE;
	if (f.param_type_2 == CPT2_FLOWINGLIQUID)
		return getParam2() & LIQUID_LEVEL_MASK;
	if(f.liquid_type == LIQUID_FLOWING) // can remove if all param_type_2 set
		return getParam2() & LIQUID_LEVEL_MASK;
	if (f.param_type_2 == CPT2_LEVELED) {
		u8 level = getParam2() & LEVELED_MASK;
		if (level)
			return level;
	}
	// Return static value from nodedef if param2 isn't used for level
	if (f.leveled > f.leveled_max)
		return f.leveled_max;
	return f.leveled;
}

s8 MapNode::setLevel(const NodeDefManager *nodemgr, s16 level)
{
	s8 rest = 0;
	const ContentFeatures &f = nodemgr->get(*this);
	if (f.param_type_2 == CPT2_FLOWINGLIQUID
			|| f.liquid_type == LIQUID_FLOWING
			|| f.liquid_type == LIQUID_SOURCE) {
		if (level <= 0) { // liquid can’t exist with zero level
			setContent(CONTENT_AIR);
			return 0;
		}
		if (level >= LIQUID_LEVEL_SOURCE) {
			rest = level - LIQUID_LEVEL_SOURCE;
			setContent(f.liquid_alternative_source_id);
			setParam2(0);
		} else {
			setContent(f.liquid_alternative_flowing_id);
			setParam2((level & LIQUID_LEVEL_MASK) | (getParam2() & ~LIQUID_LEVEL_MASK));
		}
	} else if (f.param_type_2 == CPT2_LEVELED) {
		if (level < 0) { // zero means default for a leveled nodebox
			rest = level;
			level = 0;
		} else if (level > f.leveled_max) {
			rest = level - f.leveled_max;
			level = f.leveled_max;
		}
		setParam2((level & LEVELED_MASK) | (getParam2() & ~LEVELED_MASK));
	}
	return rest;
}

s8 MapNode::addLevel(const NodeDefManager *nodemgr, s16 add)
{
	s16 level = getLevel(nodemgr);
	level += add;
	return setLevel(nodemgr, level);
}

u32 MapNode::serializedLength(u8 version)
{
	if (!ser_ver_supported_read(version))
		throw VersionMismatchException("ERROR: MapNode format not supported");

	if (version == 0)
		return 1;

	if (version <= 9)
		return 2;

	if (version <= 23)
		return 3;

	return 4;
}
void MapNode::serialize(u8 *dest, u8 version) const
{
	if (!ser_ver_supported_write(version))
		throw VersionMismatchException("ERROR: MapNode format not supported");

	// Can't do this anymore; we have 16-bit dynamically allocated node IDs
	// in memory; conversion just won't work in this direction.
	if(version < 24)
		throw SerializationError("MapNode::serialize: serialization to "
				"version < 24 not possible");

	writeU16(dest+0, param0);
	writeU8(dest+2, param1);
	writeU8(dest+3, param2);
}
void MapNode::deSerialize(const u8 *source, u8 version)
{
	if (!ser_ver_supported_read(version))
		throw VersionMismatchException("ERROR: MapNode format not supported");

	if(version <= 21)
	{
		deSerialize_pre22(source, version);
		return;
	}

	if(version >= 24){
		param0 = readU16(source+0);
		param1 = readU8(source+2);
		param2 = readU8(source+3);
	}else{
		param0 = readU8(source+0);
		param1 = readU8(source+1);
		param2 = readU8(source+2);
		if(param0 > 0x7F){
			param0 |= ((param2&0xF0)<<4);
			param2 &= 0x0F;
		}
	}
}

Buffer<u8> MapNode::serializeBulk(int version,
		const MapNode *nodes, u32 nodecount,
		u8 content_width, u8 params_width, bool is_mono_block)
{
	if (!ser_ver_supported_write(version))
		throw VersionMismatchException("ERROR: MapNode format not supported");

	sanity_check(content_width == 2);
	sanity_check(params_width == 2);

	Buffer<u8> databuf(nodecount * (content_width + params_width));

	// Writing to the buffer linearly is faster
	u8 *p = &databuf[0];
	if (is_mono_block) {
		MapNode n = nodes[0];
		for (u32 i = 0; i < nodecount; i++, p += 2)
			writeU16(p, n.param0);
		for (u32 i = 0; i < nodecount; i++, p++)
			writeU8(p, n.param1);
		for (u32 i = 0; i < nodecount; i++, p++)
			writeU8(p, n.param2);
	} else {
		for (u32 i = 0; i < nodecount; i++, p += 2)
			writeU16(p, nodes[i].param0);
		for (u32 i = 0; i < nodecount; i++, p++)
			writeU8(p, nodes[i].param1);
		for (u32 i = 0; i < nodecount; i++, p++)
			writeU8(p, nodes[i].param2);
	}

	return databuf;
}

// Deserialize bulk node data
void MapNode::deSerializeBulk(std::istream &is, int version,
		MapNode *nodes, u32 nodecount,
		u8 content_width, u8 params_width)
{
	if (!ser_ver_supported_read(version))
		throw VersionMismatchException("ERROR: MapNode format not supported");

	if (version < 22
			|| (content_width != 1 && content_width != 2)
			|| params_width != 2)
		throw SerializationError("Deserialize bulk node data error");

	// read data
	const u32 len = nodecount * (content_width + params_width);
	Buffer<u8> databuf(len);
	is.read(reinterpret_cast<char*>(*databuf), len);

	// Deserialize content
	if(content_width == 1)
	{
		for(u32 i=0; i<nodecount; i++)
			nodes[i].param0 = readU8(&databuf[i]);
	}
	else if(content_width == 2)
	{
		for(u32 i=0; i<nodecount; i++)
			nodes[i].param0 = readU16(&databuf[i*2]);
	}

	// Deserialize param1
	u32 start1 = content_width * nodecount;
	for(u32 i=0; i<nodecount; i++)
		nodes[i].param1 = readU8(&databuf[start1 + i]);

	// Deserialize param2
	u32 start2 = (content_width + 1) * nodecount;
	if(content_width == 1)
	{
		for(u32 i=0; i<nodecount; i++) {
			nodes[i].param2 = readU8(&databuf[start2 + i]);
			if(nodes[i].param0 > 0x7F){
				nodes[i].param0 <<= 4;
				nodes[i].param0 |= (nodes[i].param2&0xF0)>>4;
				nodes[i].param2 &= 0x0F;
			}
		}
	}
	else if(content_width == 2)
	{
		for(u32 i=0; i<nodecount; i++)
			nodes[i].param2 = readU8(&databuf[start2 + i]);
	}
}

/*
	Legacy serialization
*/
void MapNode::deSerialize_pre22(const u8 *source, u8 version)
{
	if(version <= 1)
	{
		param0 = source[0];
	}
	else if(version <= 9)
	{
		param0 = source[0];
		param1 = source[1];
	}
	else
	{
		param0 = source[0];
		param1 = source[1];
		param2 = source[2];
		if(param0 > 0x7f){
			param0 <<= 4;
			param0 |= (param2&0xf0)>>4;
			param2 &= 0x0f;
		}
	}

	// Convert special values from old version to new
	if(version <= 19)
	{
		// In these versions, CONTENT_IGNORE and CONTENT_AIR
		// are 255 and 254
		// Version 19 is messed up with sometimes the old values and sometimes not
		if(param0 == 255)
			param0 = CONTENT_IGNORE;
		else if(param0 == 254)
			param0 = CONTENT_AIR;
	}

	// Translate to our known version
	*this = mapnode_translate_to_internal(*this, version);
}
