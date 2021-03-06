--[[
    Ability Automator Module
]]

--TODO:
--Enable rearranging of actions (since the order determines the priority of execution)
--Finish the other evaluators

require("ext_entity")
require("aam_search")
require("aam_evaluators")
require("aam_internal")

if CActionAutomatorModule == nil then
    CActionAutomatorModule = class({constructor = function(self, hExtEntity)
        if not IsValidExtendedEntity(hExtEntity) then
            error("hExtEntity must be a valid extended entity")
        end
        if hExtEntity._hActionAutomatorModule then
            error("hExtEntity already has an AAM attached to it")
        end
        
        hExtEntity._hActionAutomatorModule = self
        
        self._bEnabled = true
        self._hExtEntity = hExtEntity
        self._tActionList = {}
		self._tSavedTargets = {}
        
        self._nCurrentStep = 0
        self._nMaxSteps = 0
        
        --This is kind of messy... maybe there's a better way to do these things?
        self._bSkipFlag = false
        self._bStopFlag = false
        
        hExtEntity:SetThink("OnThink", self, "AAMThink", 0.1)
    end},
    {}, nil)
end

function CActionAutomatorModule:GetEntity()
	return self._hExtEntity
end

function CActionAutomatorModule:GetCurrentAction()
	return self._tActionList[self._nCurrentStep]
end

function CActionAutomatorModule:PerformAction(tActionDef)
    if tActionDef then
        local hExtEntity      = self.hExtEntity
        local nTargetFlags    = tActionDef.TargetFlags
        local tConditionFlags = {tActionDef.ConditionFlags1 or 0, tActionDef.ConditionFlags2 or 0}
        local hAction         = tActionDef.Action
        
        if not nTargetFlags or not hAction then
            return false
        end
        
        local tTargetList = nil
        local nTargetTeam = bit32.extract(nTargetFlags, 0, 2)
        local nTargetSelector = bit32.extract(nTargetFlags, 2, 6)
        local fMinDistance = stAAMDistanceLookupTable[bit32.extract(tConditionFlags[1], 0, 3)] or 0.0
        local fMaxDistance = stAAMDistanceLookupTable[bit32.extract(tConditionFlags[1], 3, 3)] or 1800.0
        local bDeadFlag = (bit32.extract(tConditionFlags[2], 0, 1) == 1)
        
        if nTargetTeam == AAM_TARGET_RELATION_SELF then
            tTargetList = {hExtEntity}
        else
            tTargetList = GetAllUnits(hExtEntity, nTargetTeam, fMinDistance, fMaxDistance, bDeadFlag and DOTA_UNIT_TARGET_FLAG_DEAD or 0)
        end
        
        if tTargetList == nil or next(tTargetList) == nil then
            return false
        end
		
        local nFlagOffset = 0
        local nFlagNumber = 1
        for k,v in ipairs(stConditionTable) do
            local pEvaluatorFunction = v[1]
            local nValue = bit32.extract(tConditionFlags[nFlagNumber], nFlagOffset, v[2])
            
            if nValue ~= 0 then
                tTargetList = pEvaluatorFunction(nValue, tTargetList, self)
                if next(tTargetList) == nil then
                    return false
                end
            end
            
            nFlagOffset = nFlagOffset + v[2]
            if nFlagOffset >= 32 then
                nFlagOffset = 0
                nFlagNumber = nFlagNumber + 1
            end
        end
        
        for k,v in pairs(tTargetList) do
            if not IsValidEntity(v) or not (v:IsAlive() or bDeadFlag) or v:IsInvulnerable() or not hExtEntity:CanEntityBeSeenByMyTeam(v) then
                tTargetList[k] = nil
            end
        end
        
        local hSelectorFunction = stAAMSelectorTable[nTargetSelector]
        local hTarget = hSelectorFunction(self._hEntity, tTargetList)
        
        local hInternalAction = stInternalAbilityLookupTable[hAction]
        if hInternalAction then
            return hInternalAction(hExtEntity, self, hTarget)
        elseif hExtEntity:CanCastAbility(hAction:GetAbilityName(), hTarget) then
            local nActionBehavior = hAction:GetBehavior()
            local nPlayerIndex = hEntity:GetPlayerOwnerID()
            if (bit32.btest(nActionBehavior, DOTA_ABILITY_BEHAVIOR_NO_TARGET)) then
				hExtEntity:IssueOrder(DOTA_UNIT_ORDER_CAST_NO_TARGET, nil, hAction, nil, false)
            elseif (bit32.btest(nActionBehavior, DOTA_ABILITY_BEHAVIOR_POINT) or bit32.btest(nActionBehavior, DOTA_ABILITY_BEHAVIOR_AOE)) then
				hExtEntity:IssueOrder(DOTA_UNIT_ORDER_CAST_POSITION, nil, hAction, hTarget:GetAbsOrigin(), false)
            elseif (bit32.btest(nActionBehavior, DOTA_ABILITY_BEHAVIOR_UNIT_TARGET)) then
				hExtEntity:IssueOrder(DOTA_UNIT_ORDER_CAST_TARGET, hTarget, hAction, nil, false)
            end
            return true and not self._bSkipFlag
        end
    end
    return false
end

function CActionAutomatorModule:Step()
    local tActionDef = self:GetCurrentAction()
    if tActionDef then
        self._bSkipFlag = false
        if self:PerformAction(tActionDef) == false then
            self._nCurrentStep = self._nCurrentStep + 1
            self:Step()
        end
    end
end

function CActionAutomatorModule:OnThink()
    local hEntity = self._hEntity
    if self._bEnabled and hEntity then
        if hEntity:IsAlive() and hEntity:GetCurrentActiveAbility() == nil then
            --Stop auto attacking and enable automation
            if hEntity:IsAttacking() then
                if not hEntity:AttackReady() and not self._bStopFlag then
                    hEntity:Stop()
                    self._bStopFlag = true
                elseif hEntity:AttackReady() then
                    self._bStopFlag = false
                end
            end
            
            self._nCurrentStep = 1
			self._tSavedTargets = {}
            self:Step()
        end
    end
    return 0.1
end

function CActionAutomatorModule:SkipAction(nNextStep)
    if not nNextStep then
        nNextStep = self._nCurrentStep
    end
    if nNextStep >= self._nCurrentStep and nNextStep <= self._nMaxSteps then
        self._bSkipFlag = true
        self._nCurrentStep = nNextStep
    end
end

function CActionAutomatorModule:Insert(hAction, nTargetFlags, nConditionFlags1, nConditionFlags2)
    if not hAction then
        error("hAction must be defined")
    end
    
    local tActionDef =
    {
        Action = hAction,
        TargetFlags = nTargetFlags or 0,
        ConditionFlags1 = nConditionFlags1 or 0,
        ConditionFlags2 = nConditionFlags2 or 0,
    }
    
    table.insert(self._tActionList, tActionDef)
    self._nMaxSteps = self._nMaxSteps + 1
end
