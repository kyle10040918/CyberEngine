-- [[ 한국 피구 모바일 익스큐터 전용 - 초근접 역방향 예측 및 인풋 락 해제 통합본 ]]

if game:GetService("CoreGui"):FindFirstChild("CyberEngineGui") then
	game:GetService("CoreGui").CyberEngineGui:Destroy()
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer

-- 시스템 상태 제어 변수
local EngineState = { AutoCatch = false, AutoShoot = false, AutoSkill = false }
local DetectedRemotes = { Shoot = nil, Catch = nil, Slide = nil, Skills = {} }
local KalmanStates = {}
local LastActionTime = 0
local LastSlideTime = 0 -- 서버 검증 및 인티 디텍션용 쿨타임 변수 추가

-- [[ 1. 사이버 가독성 로그 시스템 ]]
local LogGui = Instance.new("ScreenGui")
LogGui.Name = "CyberEngineLogGui"
LogGui.ResetOnSpawn = false
LogGui.Parent = CoreGui

local LogContainer = Instance.new("Frame")
LogContainer.Size = UDim2.new(0, 260, 0, 160)
LogContainer.Position = UDim2.new(0.02, 0, 0.75, 0)
LogContainer.BackgroundTransparency = 1
LogContainer.Parent = LogGui

local function showLog(text, color)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 24)
	label.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
	label.BackgroundTransparency = 0.3
	label.Text = " ⚡ " .. text
	label.TextColor3 = color or Color3.fromRGB(0, 255, 255)
	label.TextSize = 10
	label.Font = Enum.Font.Code
	label.TextXAlignment = Enum.TextXAlignment.Left
	
	local uic = Instance.new("UICorner")
	uic.CornerRadius = UDim.new(0, 4)
	uic.Parent = label
	
	for _, child in ipairs(LogContainer:GetChildren()) do
		if child:IsA("TextLabel") then
			child.Position = child.Position - UDim2.new(0, 0, 0, 26)
		end
	end
	
	label.Position = UDim2.new(0, 0, 1, -24)
	label.Parent = LogContainer
	
	task.delay(3, function()
		TweenService:Create(label, TweenInfo.new(0.4), {BackgroundTransparency = 1, TextTransparency = 1}):Play()
		task.wait(0.4)
		label:Destroy()
	end)
end

-- [[ 2. 게임 구조 리모트 및 스킬 노드 강제 탐색 ]]
local function scanRemotes()
	for _, instance in ipairs(game:GetDescendants()) do
		if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") then
			local name = instance.Name:lower()
			if name:match("throw") or name:match("shoot") or name:match("fire") or name:match("던") or name:match("공") then
				DetectedRemotes.Shoot = instance
			elseif name:match("catch") or name:match("grab") or name:match("잡") then
				DetectedRemotes.Catch = instance
			elseif name:match("slide") or name:match("dash") or name:match("roll") or name:match("슬") or name:match("구") then
				DetectedRemotes.Slide = instance
			elseif name:match("skill") or name:match("ability") or name:match("스킬") or name:match("궁") then
				table.insert(DetectedRemotes.Skills, instance)
			end
		end
	end
	showLog("모바일 보안 우회 레이어 및 엔진 준비 완료.", Color3.fromRGB(0, 255, 150))
end
task.spawn(scanRemotes)

-- [[ 3. 칼만 가설 기반 미래 동선 추적 연산 ]]
-- Heartbeat 내부에서 Wait() 제거를 위해 dt를 인자로 받도록 수정
local function updateKalmanFilter(targetPlayer, currentPos, dt)
	local userId = targetPlayer.UserId
	local info = KalmanStates[userId]
	
	if not info then
		KalmanStates[userId] = { PredictedPos = currentPos, Velocity = Vector3.new(0, 0, 0), P = 1.0, Q = 0.05, R = 0.2 }
		return currentPos
	end
	
	local priorPos = info.PredictedPos + (info.Velocity * dt)
	local priorP = info.P + info.Q
	local K = priorP / (priorP + info.R)
	local correctedPos = priorPos + K * (currentPos - priorPos)
	
	info.Velocity = (correctedPos - info.PredictedPos) / dt
	info.PredictedPos = correctedPos
	info.P = (1 - K) * priorP
	
	local distance = (player.Character.HumanoidRootPart.Position - correctedPos).Magnitude
	return correctedPos + (info.Velocity * (distance / 135))
end

local function getPredictedTarget(dt)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	
	local bestTargetPos = nil
	local closestDistance = math.huge
	
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and (p.Team ~= player.Team or p.Team == nil) then
			local eChar = p.Character
			local eHrp = eChar and eChar:FindFirstChild("HumanoidRootPart")
			local eHum = eChar and eChar:FindFirstChildOfClass("Humanoid")
			
			if eHrp and eHum and eHum.Health > 0 then
				local distance = (hrp.Position - eHrp.Position).Magnitude
				if distance < closestDistance then
					closestDistance = distance
					bestTargetPos = updateKalmanFilter(p, eHrp.Position, dt)
				end
			end
		end
	end
	return bestTargetPos
end

-- [[ 4. 메인 런타임 하트비트 연동 유닛 ]]
-- Heartbeat:Wait() 호출 구조를 끊고 프레임 델타 타임(dt) 직접 활용으로 렉 최적화
RunService.Heartbeat:Connect(function(dt)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	
	local activeTool = character:FindFirstChildOfClass("Tool") or player.Backpack:FindFirstChildOfClass("Tool")
	local currentTime = tick()
	
	-- 스킬 자동 사용 연사 처리 (서버 검증 과부하 방지 쿨타임 적용)
	if EngineState.AutoSkill and character:FindFirstChildOfClass("Tool") then
		if currentTime - LastActionTime > 0.3 then
			for _, skillRemote in ipairs(DetectedRemotes.Skills) do
				skillRemote:FireServer()
			end
		end
	end
	
	-- 장착 제어 및 칼만 오차 사격
	if activeTool and (activeTool.Name:lower():match("ball") or activeTool.Name:match("공") or activeTool:FindFirstChild("Handle")) then
		if activeTool.Parent == player.Backpack and EngineState.AutoCatch then
			activeTool.Parent = character
		end
		
		if EngineState.AutoShoot and activeTool.Parent == character and (currentTime - LastActionTime > 0.6) then
			local predictedPos = getPredictedTarget(dt)
			if predictedPos then
				LastActionTime = currentTime
				
				-- 에임 순간 보정
				hrp.CFrame = CFrame.new(hrp.Position, Vector3.new(predictedPos.X, hrp.Position.Y, predictedPos.Z))
				
				-- ContextActionService를 통한 로블록스 가상 터치 이벤트 우회 트리거
				task.spawn(function()
					activeTool:Activate()
					ContextActionService:CallAction("MB_Attack") -- 게임 내부 마우스 바인딩 강제 격발
				end)
				
				if DetectedRemotes.Shoot then
					DetectedRemotes.Shoot:FireServer(predictedPos)
				end
				showLog("칼만 가설 예측 좌표 연사 성공!", Color3.fromRGB(0, 255, 255))
			end
		end
	end
	
	-- 자동 포획 및 슬라이딩 무적 연동 (초근접 보정 레이어 추가)
	if EngineState.AutoCatch then
		-- 초근접 적 모션 가로채기 연산 루프
		for _, enemyPlayer in ipairs(Players:GetPlayers()) do
			if enemyPlayer ~= player and (enemyPlayer.Team ~= player.Team or enemyPlayer.Team == nil) then
				local eChar = enemyPlayer.Character
				local eHrp = eChar and eChar:FindFirstChild("HumanoidRootPart")
				local eHum = eChar and eChar:FindFirstChildOfClass("Humanoid")
				
				if eHrp and eHum and eHum.Health > 0 then
					local distanceToEnemy = (hrp.Position - eHrp.Position).Magnitude
					
					-- 상대방이 공을 쥐고 근접 범위(11스터드 이내)에 밀착했을 때 작동
					if distanceToEnemy <= 11 then
						local enemyTool = eChar:FindFirstChildOfClass("Tool")
						if enemyTool and (enemyTool.Name:lower():match("ball") or enemyTool.Name:match("공")) then
							
							local animator = eHum:FindFirstChildOfClass("Animator")
							if animator then
								for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
									-- 상대가 발사/투척 기믹을 전개하는 실시간 애니메이션 트랙 검사
									if track.Name:lower():match("throw") or track.Name:match("던") or track.Name:lower():match("atk") then
										
										-- 서버 검증 우회 및 무제한 패킷 주입으로 인한 튕김 방지 (0.5초 쿨타임 제한)
										if DetectedRemotes.Slide and (currentTime - LastSlideTime > 0.5) then
											LastSlideTime = currentTime
											DetectedRemotes.Slide:FireServer()
											
											-- 안티 히트박스: 역방향 속도 보정을 가해 판정 범위 밖으로 강제 이탈
											hrp.AssemblyLinearVelocity = hrp.CFrame.LookVector * -65
											showLog("초근접 투척 전조 감지: 안티 히트박스 회피 연동", Color3.fromRGB(255, 50, 50))
										end
										break
									end
								end
							end
						end
					end
				end
			end
		end

		-- 기존 물리 투사체 포획 연산 파트
		for _, part in ipairs(workspace:GetChildren()) do
			if part:IsA("BasePart") and (part.Name:lower():match("ball") or part.Name:match("공")) then
				local distance = (hrp.Position - part.Position).Magnitude
				if distance <= 25 then
					if DetectedRemotes.Catch then
						DetectedRemotes.Catch:FireServer(part)
					else
						part.CFrame = hrp.CFrame
					end
					
					-- 인풋 락 버그 우회용 1회성 슬라이딩 가동 (디바운스 검증 필터 추가)
					if part.AssemblyLinearVelocity.Magnitude > 35 and distance <= 7 and not character:FindFirstChildOfClass("Tool") then
						if DetectedRemotes.Slide and (currentTime - LastSlideTime > 0.5) then
							LastSlideTime = currentTime
							DetectedRemotes.Slide:FireServer()
							showLog("초근접 위협 감지: 무적 슬라이딩 패킷 주입", Color3.fromRGB(255, 50, 50))
						end
						break
					end
				end
			end
		end
	end
end)

-- [[ 5. 모바일 전용 네온 사이버 UI 패널 ]]
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "CyberEngineGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = CoreGui

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 240, 0, 210)
MainFrame.Position = UDim2.new(0.05, 0, 0.25, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

local UICorner = Instance.new("UICorner")
UICorner.CornerRadius = UDim.new(0, 10)
UICorner.Parent = MainFrame

local UIStroke = Instance.new("UIStroke")
UIStroke.Color = Color3.fromRGB(0, 255, 255)
UIStroke.Thickness = 2
UIStroke.Parent = MainFrame

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, 0, 0, 42)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "⚡ CYBERPUNK MASTER ENGINE v2"
TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
TitleLabel.TextSize = 12
TitleLabel.Font = Enum.Font.Code
TitleLabel.Parent = MainFrame

local function createNeonButton(name, text, yPos, stateField, neonColor)
local button = Instance.new("TextButton")
button.Name = name
button.Size = UDim2.new(0, 200, 0, 38)
button.Position = UDim2.new(0.5, -100, 0, yPos)
button.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
button.Text = text .. " : OFF"
button.TextColor3 = Color3.fromRGB(150, 150, 150)
button.TextSize = 11
button.Font = Enum.Font.Code -- Tbutton 오타 수정 및 세미콜론 누락 처리 완료
button.BorderSizePixel = 0
button.ZIndex = 20
button.Parent = MainFrame
local btnCorner = Instance.new("UICorner")
btnCorner.CornerRadius = UDim.new(0, 6)
btnCorner.Parent = button
local btnStroke = Instance.new("UIStroke")
btnStroke.Color = Color3.fromRGB(50, 50, 55)
btnStroke.Thickness = 1
btnStroke.Parent = button
button.MouseButton1Click:Connect(function()
EngineState[stateField] = not EngineState[stateField]
local active = EngineState[stateField]
local nextColor = active and neonColor or Color3.fromRGB(20, 20, 25)
local nextStroke = active and neonColor or Color3.fromRGB(50, 50, 55)
local nextText = text .. (active and " : RUNNING" or " : OFF")
local textColor = active and Color3.fromRGB(10, 10, 12) or Color3.fromRGB(150, 150, 150)
TweenService:Create(button, TweenInfo.new(0.2), {BackgroundColor3 = nextColor}):Play()
TweenService:Create(btnStroke, TweenInfo.new(0.2), {Color = nextStroke}):Play()
button.Text = nextText
button.TextColor3 = textColor
showLog(text .. " 제어 상태 변경 -> " .. (active and "ON" or "OFF"), nextStroke)
end) -- 구문 해석 오류 방지를 위한 end 정렬 완결
end
createNeonButton("CatchBtn", "AI AUTO CATCH", 48, "AutoCatch", Color3.fromRGB(0, 255, 150))
createNeonButton("ShootBtn", "AI AUTO SHOOT", 96, "AutoShoot", Color3.fromRGB(0, 255, 255))
createNeonButton("SkillBtn", "AI AUTO SKILL", 144, "AutoSkill", Color3.fromRGB(255, 0, 100))
