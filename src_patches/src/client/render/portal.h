// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once

#include "pipeline.h"
#include "portal_manager.h"
#include "irrlichttypes_bloated.h"
#include <memory>

namespace scene { class ICameraSceneNode; class ISceneManager; }
namespace video { class IVideoDriver; class ITexture; }
class Sky;

// Shared RTT state for portal rendering when post-processing is enabled.
// PortalPrepareStep and PortalQuadStep both reference the same instance.
struct PortalRTTData {
	scene::ICameraSceneNode *vcam[MAX_PORTALS] = {};
	video::ITexture         *rtex[MAX_PORTALS] = {};
	v2u32                    rtex_size = {0, 0};
	// Saved from PortalPrepareStep::run(), consumed by PortalQuadStep::run().
	scene::ICameraSceneNode *main_cam = nullptr;
	// Camera offset in world units (raw world pos - rendering pos).
	v3f cam_offset_world = {0.0f, 0.0f, 0.0f};
	// Camera position at the time RTTs were last rendered (for intra-frame teleport).
	v3f  rtt_cam_pos    = {0.0f, 0.0f, 0.0f};
	bool rtt_cam_valid  = false;
	// Non-owning pointer to the scene render target (TextureBuffer in PP mode).
	// Used to restore the render target after re-rendering RTTs in PortalQuadStep.
	RenderTarget *scene_rt = nullptr;
	// Non-owning pointer to the sky node; set each frame from PipelineContext.
	Sky *sky = nullptr;
	Sky *overworld_sky = nullptr;

	~PortalRTTData();
	void ensureCameras(scene::ISceneManager *smgr);
	void ensureRenderTextures(video::IVideoDriver *driver, v2u32 size);
};

// Step 1 of 2 for post-processing pipeline.
// Renders each portal's RTT using a virtual camera.
// Insert BEFORE the Draw3D step. Leaves render target at FBO=0/screen so that
// Draw3D's m_target->activate() can cleanly rebind the TextureBuffer FBO.
class PortalPrepareStep : public RenderStep {
public:
	explicit PortalPrepareStep(std::shared_ptr<PortalRTTData> d) : m_data(std::move(d)) {}
	void setRenderSource(RenderSource *) override {}
	void setRenderTarget(RenderTarget *) override {}
	void reset(PipelineContext &) override {}
	void run(PipelineContext &ctx) override;
private:
	std::shared_ptr<PortalRTTData> m_data;
};

// Step 2 of 2 for post-processing pipeline.
// Draws portal quads into the current render target (TextureBuffer when PP is on).
// Insert AFTER Draw3D but BEFORE post-processing so the 3D depth buffer is intact.
class PortalQuadStep : public RenderStep {
public:
	explicit PortalQuadStep(std::shared_ptr<PortalRTTData> d) : m_data(std::move(d)) {}
	void setRenderSource(RenderSource *) override {}
	void setRenderTarget(RenderTarget *) override {}
	void reset(PipelineContext &) override {}
	void run(PipelineContext &ctx) override;
private:
	std::shared_ptr<PortalRTTData> m_data;
};

// Combined step for the non-post-processing pipeline (render target is screen FBO=0).
// Renders RTTs and draws quads in one pass; no FBO cache issues at FBO=0.
class PortalRenderStep : public RenderStep {
public:
	~PortalRenderStep() override;
	void setRenderSource(RenderSource *) override {}
	void setRenderTarget(RenderTarget *) override {}
	void reset(PipelineContext &) override {}
	void run(PipelineContext &ctx) override;
private:
	PortalRTTData m_data;
};
