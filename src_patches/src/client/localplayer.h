// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#pragma once

#include "player.h"
#include "constants.h"
#include "lighting.h"
#include <string>

class Client;
class ClientActiveObject;
class Environment;
class GenericCAO;
class Map;
struct CollisionInfo;
struct collisionMoveResult;

enum class LocalPlayerAnimation
{
	NO_ANIM,
	WALK_ANIM,
	DIG_ANIM,
	WD_ANIM // walking + digging
};

struct PlayerSettings
{
	bool free_move = false;
	bool pitch_move = false;
	bool fast_move = false;
	bool continuous_forward = false;
	bool always_fly_fast = false;
	bool aux1_descends = false;
	bool noclip = false;
	bool autojump = false;

	void readGlobalSettings();
	void registerSettingsCallback();
	void deregisterSettingsCallback();

private:
	static void settingsChangedCallback(const std::string &name, void *data);
};

class LocalPlayer : public Player
{
public:

	LocalPlayer(Client *client, const std::string &name);
	virtual ~LocalPlayer();

	// Initialize hp to 0, so that no hearts will be shown if server
	// doesn't support health points
	u16 hp = 0;
	bool touching_ground = false;
	// This oscillates so that the player jumps a bit above the surface
	bool in_liquid = false;
	// This is more stable and defines the maximum speed of the player
	bool in_liquid_stable = false;
	// Slows down the player when moving through
	u8 move_resistance = 0;
	bool is_climbing = false;
	bool swimming_vertical = false;
	bool swimming_pitch = false;

	f32 gravity = 0; // total downwards acceleration

	void move(f32 dtime, Environment *env);
	void move(f32 dtime, Environment *env,
			std::vector<CollisionInfo> *collision_info);

	void applyControl(float dtime, Environment *env);

	v3s16 getStandingNodePos();
	v3s16 getFootstepNodePos();

	// Used to check if anything changed and prevent sending packets if not
	v3f last_position;
	v3f last_speed;
	float last_pitch = 0.0f;
	float last_yaw = 0.0f;
	u32 last_keyPressed = 0;
	u8 last_camera_fov = 0;
	u8 last_wanted_range = 0;
	bool last_camera_inverted = false;
	f32 last_movement_speed = 0.0f;
	f32 last_movement_dir = 0.0f;

	float camera_impact = 0.0f;

	bool makes_footstep_sound = true;

	LocalPlayerAnimation last_animation = LocalPlayerAnimation::NO_ANIM;
	float last_animation_speed = 0.0f;

	std::string hotbar_image = "";
	std::string hotbar_selected_image = "";
	/// Temporary player inventory formspec. Empty value = feature inactive.
	std::string inventory_formspec_override;

	video::SColor light_color = video::SColor(255, 255, 255, 255);

	float hurt_tilt_timer = 0.0f;
	float hurt_tilt_strength = 0.0f;

	GenericCAO *getCAO() const { return m_cao; }

	ClientActiveObject *getParent() const;

	void setCAO(GenericCAO *toset)
	{
		assert(!m_cao); // Pre-condition
		m_cao = toset;
	}

	u16 getBreath() const { return m_breath; }
	void setBreath(u16 breath) { m_breath = breath; }

	v3s16 getLightPosition() const;

	void setYaw(f32 yaw) { m_yaw = yaw; }
	f32 getYaw() const { return m_yaw; }

	void setPitch(f32 pitch) { m_pitch = pitch; }
	f32 getPitch() const { return m_pitch; }

	inline void setPosition(const v3f &position)
	{
		m_position = position;
		m_sneak_node_exists = false;
	}
	inline void addPosition(const v3f &added_pos)
	{
		m_position += added_pos;
		m_sneak_node_exists = false;
	}

	v3f getPosition() const { return m_position; }

	// Non-transformed eye offset getters
	// For accurate positions, use the Camera functions
	v3f getEyePosition() const { return m_position + getEyeOffset(); }
	v3f getEyeOffset() const;
	void setEyeHeight(float eye_height) { m_eye_height = eye_height; }

	void setCollisionbox(const aabb3f &box) { m_collisionbox = box; }

	const aabb3f& getCollisionbox() const { return m_collisionbox; }

	float getZoomFOV() const { return m_zoom_fov; }
	void setZoomFOV(float zoom_fov) { m_zoom_fov = zoom_fov; }

	bool getAutojump() const { return m_autojump; }

	bool isDead() const;

	inline void addVelocity(const v3f &vel)
	{
		m_added_velocity += vel;
	}

	void snapView(f32 yaw, f32 pitch, f32 roll = 0.0f)
	{
		m_snap_yaw   = yaw;
		m_snap_pitch = pitch;
		m_snap_roll  = roll;
		m_snap_view  = true;
	}

	void snapRoll(f32 roll)
	{
		// Don't let a roll-only update overwrite a full teleport snap that
		// hasn't been consumed yet; that would suppress the yaw/pitch update.
		if (m_snap_view && !m_snap_roll_only && !m_snap_pitch_only)
			return;
		m_snap_roll      = roll;
		m_snap_roll_only = true;
		m_snap_view      = true;
	}

	void snapPitch(f32 pitch)
	{
		// Don't let a pitch-only update overwrite a full teleport snap.
		if (m_snap_view && !m_snap_pitch_only && !m_snap_roll_only)
			return;
		m_snap_pitch      = pitch;
		m_snap_pitch_only = true;
		m_snap_view       = true;
	}

	// Portal warp: a decaying camera offset that makes a hard teleport look like
	// a smooth roto-translation from the entry pose to the exit pose.  The player
	// is already at the exit; these offsets (pos in BS, yaw/pitch in degrees, roll
	// in radians) start at entry-minus-exit and ease to zero over m_warp_dur, so
	// the rendered camera starts at the entry pose and catches up to the live one.
	void startPortalWarp(const v3f &pos_off, f32 yaw_off, f32 pitch_off,
			f32 roll_off, f32 dur)
	{
		m_warp_pos_off   = pos_off;
		m_warp_yaw_off   = yaw_off;
		m_warp_pitch_off = pitch_off;
		m_warp_roll_off  = roll_off;
		m_warp_dur       = dur;
		m_warp_time      = 0.0f;
		m_warp_active    = (dur > 0.0f);
	}

	// Advance the warp timer by dt and return the current offset weight (1 at the
	// start, easing to 0 at m_warp_dur; 0 when inactive).  Camera::update calls
	// this once per frame and scales the stored offsets by the result.
	f32 stepPortalWarp(f32 dt)
	{
		if (!m_warp_active)
			return 0.0f;
		m_warp_time += dt;
		if (m_warp_time >= m_warp_dur) {
			m_warp_active = false;
			return 0.0f;
		}
		f32 p = m_warp_time / m_warp_dur;       // 0 → 1
		return 1.0f - p * p * (3.0f - 2.0f * p); // 1 → 0, smoothstep ease
	}

	bool m_snap_view       = false;
	bool m_snap_roll_only  = false;
	bool m_snap_pitch_only = false;
	f32  m_snap_yaw   = 0.0f;
	f32  m_snap_pitch = 0.0f;
	f32  m_snap_roll  = 0.0f;
	f32  m_camera_roll = 0.0f;  // persistent camera roll (radians), visual only

	// Portal warp state (see startPortalWarp). Offsets decay over m_warp_dur.
	bool m_warp_active    = false;
	f32  m_warp_time      = 0.0f;
	f32  m_warp_dur       = 0.0f;
	f32  m_warp_yaw_off   = 0.0f;  // degrees
	f32  m_warp_pitch_off = 0.0f;  // degrees
	f32  m_warp_roll_off  = 0.0f;  // radians
	v3f  m_warp_pos_off   = v3f(0.0f, 0.0f, 0.0f);  // BS units

	// Set by TOCLIENT_PORTAL_TELEPORT to override sunlight_seen for N frames,
	// preventing a 1-2 frame sky-type glitch after dimension change.
	int  sky_sunlit_override_frames = 0;
	bool sky_sunlit_override_value  = true;
	// Set alongside sky_sunlit_override to trigger a full sky reset on first frame.
	bool sky_override_reset_pending = false;
	// Portal slot whose sky_type_index is applied to the main sky on reset.
	int  sky_snap_slot = -1;

	inline Lighting& getLighting() { return m_lighting; }

	inline PlayerSettings &getPlayerSettings() { return m_player_settings; }

private:
	void accelerate(const v3f &target_speed, const f32 max_increase_H,
		const f32 max_increase_V, const bool use_pitch);
	bool updateSneakNode(Map *map, const v3f &position, const v3f &sneak_max);
	float getSlipFactor(Environment *env, const v3f &speedH);
	void old_move(f32 dtime, Environment *env,
			std::vector<CollisionInfo> *collision_info);
	void handleAutojump(f32 dtime, Environment *env,
		const collisionMoveResult &result,
		v3f position_before_move, v3f speed_before_move);

	v3f m_position;
	v3s16 m_standing_node;

	v3s16 m_sneak_node = v3s16(32767, 32767, 32767);
	// Stores the top bounding box of m_sneak_node
	aabb3f m_sneak_node_bb_top = aabb3f(0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f);
	// Whether the player is allowed to sneak
	bool m_sneak_node_exists = false;
	// Whether a "sneak ladder" structure is detected at the players pos
	// see detectSneakLadder() in the .cpp for more info (always false if disabled)
	bool m_sneak_ladder_detected = false;

	// ***** Variables for temporary option of the old move code *****
	// Stores the max player uplift by m_sneak_node
	f32 m_sneak_node_bb_ymax = 0.0f;
	// Whether recalculation of m_sneak_node and its top bbox is needed
	bool m_need_to_get_new_sneak_node = true;
	// Node below player, used to determine whether it has been removed,
	// and its old type
	v3s16 m_old_node_below = v3s16(32767, 32767, 32767);
	std::string m_old_node_below_type = "air";
	// ***** End of variables for temporary option *****

	bool m_can_jump = false;
	bool m_disable_jump = false;
	bool m_disable_descend = false;
	u16 m_breath = PLAYER_MAX_BREATH_DEFAULT;
	f32 m_yaw = 0.0f;
	f32 m_pitch = 0.0f;
	aabb3f m_collisionbox = aabb3f(-BS * 0.30f, 0.0f, -BS * 0.30f, BS * 0.30f,
		BS * 1.75f, BS * 0.30f);
	float m_eye_height = 1.625f;
	float m_zoom_fov = 0.0f;
	bool m_autojump = false;
	float m_autojump_time = 0.0f;

	v3f m_added_velocity = v3f(0.0f); // in BS-space; cleared on each move()

	GenericCAO *m_cao = nullptr;
	Client *m_client;

	PlayerSettings m_player_settings;
	Lighting m_lighting;
};
