GSimSpeed = GSimSpeed or {}
GSimSpeed.IsEnabled = true

CreateClientConVar("gsimspeed_hud", 0, true, false, "Toggle the Sim Speed HUD display.")

hook.Add("InitPostEntity", "SimSpeed.RequestBool", function()
	net.Start("SimSpeed.Network")
	net.SendToServer()
end)
net.Receive("SimSpeed.Network", function()
	GSimSpeed.IsEnabled = net.ReadBool()
end)

hook.Remove( "HUDPaint", "SimSpeed.HudRender")
hook.Add( "HUDPaint", "SimSpeed.HudRender", function()
	if not GSimSpeed.IsEnabled then return end
	if GetConVar("gsimspeed_hud"):GetInt() ~= 1 then return end

	local SimScale = game.GetTimeScale()
	local SimRatio = string.format( "%.2f", math.Round(SimScale, 2) )
	local Override = hook.Run("SimSpeed.OnHudRendering", SimRatio)

	if not Override then
		local BaseScrW = ScrW() * 0.01
		local BaseScrH = ScrH() * 0.01

		local cratio = math.min(255, SimScale * 255)
		draw.DrawText( "Sim Speed: " .. SimRatio, "TargetID", BaseScrW, BaseScrH, Color( 255, cratio, 0 ), TEXT_ALIGN_LEFT )
	end

end )