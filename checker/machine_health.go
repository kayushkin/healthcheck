package checker

// Machine health: the drives, batteries and reporting of every machine
// connected to llm-bridge-server, and of the machines on the servers it is
// connected to.
//
// Each check interval healthcheck reads GET /machines/stats from the bridge at
// llm_bridge_url, lists GET /peer-connections, and reads each connected
// server's machines through GET /peer-connections/{id}/proxy/machines/stats.
// Every drive, every battery and every machine's reporting becomes a resource
// in GET /api/status, and goes through the same alert path as disk-root:
// recordResourceReading.
//
// The bridge's types live in llm-bridge's msg package (MachineStatsOverview,
// PeerConnectionView). healthcheck does not depend on llm-bridge, so the
// structs below hold only the fields read here, with the same JSON names.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// Resource types the machine checks add to GET /api/status.
const (
	resourceTypeMachineStatsSource = "machine_stats_source"
	resourceTypeMachineDrive       = "machine_drive"
	resourceTypeMachineBattery     = "machine_battery"
	resourceTypeMachineReporting   = "machine_reporting"
)

// localMachineStatsSourceKey keys this host's bridge among the sources.
const localMachineStatsSourceKey = "this-server"

// machineStatsOverview mirrors llm-bridge msg.MachineStatsOverview.
type machineStatsOverview struct {
	Machine struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"machine"`
	RunnerConnected *bool         `json:"runner_connected,omitempty"`
	Latest          *machineStats `json:"latest,omitempty"`
}

// machineStats mirrors the parts of llm-bridge msg.MachineStats read here.
type machineStats struct {
	CollectedAt time.Time        `json:"collected_at"`
	Drives      []machineDrive   `json:"drives,omitempty"`
	Batteries   []machineBattery `json:"batteries,omitempty"`
}

// machineDrive mirrors llm-bridge msg.MachineDrive.
type machineDrive struct {
	MountPoint string `json:"mount_point"`
	Label      string `json:"label,omitempty"`
	TotalBytes uint64 `json:"total_bytes"`
	UsedBytes  uint64 `json:"used_bytes"`
	FreeBytes  uint64 `json:"free_bytes"`
}

// machineBatteryDischarging is llm-bridge msg.MachineBatteryDischarging.
const machineBatteryDischarging = "discharging"

// machineBattery mirrors llm-bridge msg.MachineBattery.
type machineBattery struct {
	Name             string  `json:"name"`
	ChargePercent    float64 `json:"charge_percent"`
	State            string  `json:"state"`
	SecondsRemaining *int64  `json:"seconds_remaining,omitempty"`
}

// peerConnectionView mirrors the parts of llm-bridge msg.PeerConnectionView
// read here.
type peerConnectionView struct {
	Connection struct {
		ID          string     `json:"id"`
		DisplayName string     `json:"display_name"`
		RemovedAt   *time.Time `json:"removed_at,omitempty"`
	} `json:"connection"`
	// AccessHeld is the access the other server gave this one. Without it
	// there is nothing to read there, so it is only checked for presence.
	AccessHeld      json.RawMessage `json:"access_held,omitempty"`
	OtherServerName string          `json:"other_server_name"`
	OtherServerID   string          `json:"other_server_id"`
}

// serverName is what the bridge says to show for the other server: its own
// name, and the label typed at connection only while it reports none.
func (view peerConnectionView) serverName() string {
	if view.OtherServerName != "" {
		return view.OtherServerName
	}
	return view.Connection.DisplayName
}

// bridgeHTTPStatusError is a non-2xx answer from llm-bridge-server.
type bridgeHTTPStatusError struct {
	URL        string
	StatusCode int
	Body       string
}

func (e *bridgeHTTPStatusError) Error() string {
	return fmt.Sprintf("GET %s answered %d: %s", e.URL, e.StatusCode, e.Body)
}

// machineStatsSource is one bridge's machines as last read.
type machineStatsSource struct {
	key string
	// label is how resource names refer to the server: empty for this host's
	// bridge, " via <server name>" for a connected one.
	label            string
	peerConnectionID string
	peerServerID     string
	peerServerName   string
	// overviews is the last list read successfully. When a later read fails,
	// these are judged again, so a machine whose server went quiet still ages
	// into stale rather than vanishing from the page.
	overviews []machineStatsOverview
	// readOnce is set once overviews holds a real answer.
	readOnce bool
}

// machineHealthState is what the machine checks remember between intervals.
// Guarded by Checker.mu except where noted.
type machineHealthState struct {
	// resourceStates holds the machine resources, keyed by ids rather than
	// by their display names, so a renamed machine keeps its history.
	resourceStates map[string]*ResourceState
	// sources is touched only by checkMachineHealth, which never runs twice
	// at once.
	sources map[string]*machineStatsSource
	// peersNotServingMachineStats records connections already logged as
	// answering 404, so the log says it once.
	peersNotServingMachineStats map[string]bool
	httpClient                  *http.Client
}

func newMachineHealthState(machineHealth *MachineHealthConfig) *machineHealthState {
	state := &machineHealthState{
		resourceStates:              make(map[string]*ResourceState),
		sources:                     make(map[string]*machineStatsSource),
		peersNotServingMachineStats: make(map[string]bool),
	}
	if machineHealth != nil {
		state.httpClient = &http.Client{Timeout: machineHealth.RequestTimeout}
	}
	return state
}

// getFromBridge reads one operator route of llm-bridge-server into out.
func (c *Checker) getFromBridge(ctx context.Context, path string, out any) error {
	address := strings.TrimSuffix(c.config.LLMBridgeURL, "/") + path
	if c.config.LLMBridgeServiceToken == "" {
		return fmt.Errorf("GET %s: %s is not set, and llm-bridge-server answers its operator routes only to the service token",
			address, llmBridgeServiceTokenEnvironmentVariable)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return err
	}
	request.Header.Set("X-LLM-Bridge-Service-Token", c.config.LLMBridgeServiceToken)
	request.Header.Set("Accept", "application/json")
	response, err := c.machineHealth.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode > 299 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 512))
		return &bridgeHTTPStatusError{URL: address, StatusCode: response.StatusCode, Body: strings.TrimSpace(string(body))}
	}
	if err := json.NewDecoder(response.Body).Decode(out); err != nil {
		return fmt.Errorf("GET %s: decode answer: %w", address, err)
	}
	return nil
}

// checkMachineHealth reads every source and judges every machine on it.
func (c *Checker) checkMachineHealth() {
	machineHealth := c.config.MachineHealth
	if machineHealth == nil {
		return
	}
	ctx := context.Background()
	sources := c.machineHealth.sources

	// This host's bridge, and its list of connected servers. A failure of
	// either is this source failing: both come from the same server with the
	// same token.
	local := sources[localMachineStatsSourceKey]
	if local == nil {
		local = &machineStatsSource{key: localMachineStatsSourceKey}
		sources[local.key] = local
	}
	var localOverviews []machineStatsOverview
	var peerViews []peerConnectionView
	var localErrors []string
	if err := c.getFromBridge(ctx, "/machines/stats", &localOverviews); err != nil {
		localErrors = append(localErrors, err.Error())
	} else {
		local.overviews, local.readOnce = localOverviews, true
	}
	peerListRead := true
	if err := c.getFromBridge(ctx, "/peer-connections", &peerViews); err != nil {
		localErrors = append(localErrors, err.Error())
		peerListRead = false
	}
	if len(localErrors) > 0 {
		c.recordMachineSourceReading(local, resourceReading{
			outcome:                       resourceReadingFailed,
			err:                           errors.New(strings.Join(localErrors, "; ")),
			failureWaitsForAlertThreshold: true,
		})
	} else {
		c.recordMachineSourceReading(local, resourceReading{
			outcome: resourceReadingMeasured,
			detail:  fmt.Sprintf("%d machines, %d connected servers", len(localOverviews), len(peerViews)),
		})
	}

	// Connected servers. When the list itself could not be read, keep the
	// sources already known and judge their last answers again.
	if peerListRead {
		listed := map[string]bool{localMachineStatsSourceKey: true}
		for _, view := range peerViews {
			if view.Connection.RemovedAt != nil || len(view.AccessHeld) == 0 || string(view.AccessHeld) == "null" {
				continue
			}
			key := "peer-connection:" + view.Connection.ID
			listed[key] = true
			source := sources[key]
			if source == nil {
				source = &machineStatsSource{key: key, peerConnectionID: view.Connection.ID}
				sources[key] = source
			}
			source.peerServerID = view.OtherServerID
			source.peerServerName = view.serverName()
			source.label = " via " + source.peerServerName
			c.readPeerMachineStats(ctx, source)
		}
		for key := range sources {
			if !listed[key] {
				delete(sources, key)
			}
		}
	}

	// Judge every machine on every source, and forget resources no source
	// names any more: a removed machine, an unplugged drive, a dropped peer.
	now := c.now()
	present := map[string]bool{}
	for _, source := range sources {
		present[machineSourceResourceKey(source)] = true
		for _, overview := range source.overviews {
			c.judgeMachine(source, overview, now, present)
		}
	}
	c.mu.Lock()
	for key := range c.machineHealth.resourceStates {
		if !present[key] {
			delete(c.machineHealth.resourceStates, key)
		}
	}
	c.mu.Unlock()
}

// readPeerMachineStats reads one connected server's machines and records how
// the read went.
//
// A server on a build without /machines/stats answers 404: that is "not
// reporting yet", logged once, not an outage. 401 and 403 mean the access
// this host holds there no longer works, which no one will notice unless it
// alerts. Anything else, mostly 503 peer_not_answering, is the other server
// asleep or offline: that is shown and not alerted, because its always-on
// machines alert by themselves as their last samples age.
func (c *Checker) readPeerMachineStats(ctx context.Context, source *machineStatsSource) {
	var overviews []machineStatsOverview
	path := "/peer-connections/" + url.PathEscape(source.peerConnectionID) + "/proxy/machines/stats"
	err := c.getFromBridge(ctx, path, &overviews)
	if err == nil {
		source.overviews, source.readOnce = overviews, true
		delete(c.machineHealth.peersNotServingMachineStats, source.peerConnectionID)
		c.recordMachineSourceReading(source, resourceReading{
			outcome: resourceReadingMeasured,
			detail:  fmt.Sprintf("%d machines", len(overviews)),
		})
		return
	}
	var statusError *bridgeHTTPStatusError
	if errors.As(err, &statusError) {
		switch statusError.StatusCode {
		case http.StatusNotFound:
			if !c.machineHealth.peersNotServingMachineStats[source.peerConnectionID] {
				c.machineHealth.peersNotServingMachineStats[source.peerConnectionID] = true
				log.Printf("machine health: connected server %s (connection %s) does not serve /machines/stats yet; its machines are not checked until it does: %v",
					source.peerServerName, source.peerConnectionID, err)
			}
			source.overviews = nil
			c.recordMachineSourceReading(source, resourceReading{
				outcome: resourceReadingUnavailable,
				detail:  "not reporting yet: its bridge has no /machines/stats",
			})
			return
		case http.StatusUnauthorized, http.StatusForbidden:
			c.recordMachineSourceReading(source, resourceReading{
				outcome:                       resourceReadingFailed,
				err:                           err,
				failureWaitsForAlertThreshold: true,
			})
			return
		}
	}
	c.recordMachineSourceReading(source, resourceReading{
		outcome: resourceReadingUnavailable,
		detail:  "cannot be read now: " + err.Error(),
	})
}

func machineSourceResourceKey(source *machineStatsSource) string {
	return "source/" + source.key
}

func (c *Checker) recordMachineSourceReading(source *machineStatsSource, reading resourceReading) {
	name := "machine stats from this server"
	if source.key != localMachineStatsSourceKey {
		name = "machine stats from " + source.peerServerName
	}
	key := machineSourceResourceKey(source)
	c.ensureMachineResourceState(key, ResourceState{
		Name:             name,
		Type:             resourceTypeMachineStatsSource,
		PeerConnectionID: source.peerConnectionID,
		PeerServerID:     source.peerServerID,
		PeerServerName:   source.peerServerName,
	})
	c.recordResourceReading(c.machineHealth.resourceStates, key, ResourceConfig{Name: name, Type: resourceTypeMachineStatsSource}, reading)
}

// ensureMachineResourceState creates the state at key, or refreshes the
// names on it: a machine or server can be renamed while its ids stay.
func (c *Checker) ensureMachineResourceState(key string, identity ResourceState) {
	c.mu.Lock()
	defer c.mu.Unlock()
	state := c.machineHealth.resourceStates[key]
	if state == nil {
		identity.Status = StatusUnknown
		c.machineHealth.resourceStates[key] = &identity
		return
	}
	state.Name = identity.Name
	state.Threshold = identity.Threshold
	state.MachineName = identity.MachineName
	state.PeerServerID = identity.PeerServerID
	state.PeerServerName = identity.PeerServerName
}

// judgeMachine records one machine's reporting, drives and batteries, and
// marks their keys present.
func (c *Checker) judgeMachine(source *machineStatsSource, overview machineStatsOverview, now time.Time, present map[string]bool) {
	machineHealth := c.config.MachineHealth
	machineID := overview.Machine.ID
	machineName := overview.Machine.Name
	identity := ResourceState{
		MachineID:        machineID,
		MachineName:      machineName,
		PeerConnectionID: source.peerConnectionID,
		PeerServerID:     source.peerServerID,
		PeerServerName:   source.peerServerName,
	}
	keyPrefix := "machine/" + source.key + "/" + machineID

	// Reporting.
	reportingKey := keyPrefix + "/reporting"
	present[reportingKey] = true
	reporting := identity
	reporting.Name = machineName + source.label + " reporting"
	reporting.Type = resourceTypeMachineReporting
	reporting.Threshold = 100
	c.ensureMachineResourceState(reportingKey, reporting)
	alwaysOn := machineHealth.isAlwaysOn(source.peerServerID, machineID)
	sampleIsCurrent := false
	var reading resourceReading
	switch {
	case overview.Latest == nil:
		reading = resourceReading{outcome: resourceReadingUnavailable, detail: "has never reported"}
	default:
		// The age is measured against the sample's collected_at, which the
		// machine's own clock wrote. A sample from the future counts as new.
		age := now.Sub(overview.Latest.CollectedAt)
		if age < 0 {
			age = 0
		}
		sampleIsCurrent = age < machineHealth.StaleAfter
		// usage_pct for reporting is the age as a share of stale_after, so
		// 100 is the line, the same way it reads for a drive.
		agePercent := float64(age) / float64(machineHealth.StaleAfter) * 100
		detail := fmt.Sprintf("last sample %s ago%s", age.Round(time.Second), describeRunnerConnection(overview.RunnerConnected))
		switch {
		case sampleIsCurrent:
			reading = resourceReading{outcome: resourceReadingMeasured, usagePercent: agePercent, detail: detail}
		case alwaysOn:
			reading = resourceReading{
				outcome:           resourceReadingMeasured,
				usagePercent:      agePercent,
				detail:            detail,
				thresholdBreached: true,
				breachDescription: fmt.Sprintf("no sample for %s; an always-on machine must report every %s", age.Round(time.Second), machineHealth.StaleAfter),
			}
		default:
			reading = resourceReading{
				outcome:      resourceReadingUnavailable,
				usagePercent: agePercent,
				detail:       detail + "; not listed as always-on, so its silence does not alert",
			}
		}
	}
	c.recordResourceReading(c.machineHealth.resourceStates, reportingKey, ResourceConfig{Name: reporting.Name, Type: reporting.Type}, reading)

	if overview.Latest == nil {
		return
	}
	staleNote := ""
	if !sampleIsCurrent {
		staleNote = fmt.Sprintf(" (sample from %s, too old to judge)", overview.Latest.CollectedAt.UTC().Format(time.RFC3339))
	}

	// Drives.
	for _, drive := range overview.Latest.Drives {
		key := keyPrefix + "/drive/" + drive.MountPoint
		present[key] = true
		resource := identity
		resource.Name = "drive " + drive.MountPoint + " on " + machineName + source.label
		resource.Type = resourceTypeMachineDrive
		resource.Threshold = machineHealth.DriveUsageThresholdPercent
		resource.DriveMountPoint = drive.MountPoint
		c.ensureMachineResourceState(key, resource)
		c.recordResourceReading(c.machineHealth.resourceStates, key, ResourceConfig{Name: resource.Name, Type: resource.Type},
			judgeDrive(drive, machineHealth.DriveUsageThresholdPercent, sampleIsCurrent, staleNote))
	}

	// Batteries.
	for _, battery := range overview.Latest.Batteries {
		key := keyPrefix + "/battery/" + battery.Name
		present[key] = true
		resource := identity
		resource.Name = "battery " + battery.Name + " on " + machineName + source.label
		resource.Type = resourceTypeMachineBattery
		resource.Threshold = 100 - machineHealth.BatteryLowChargeThresholdPercent
		resource.BatteryName = battery.Name
		c.ensureMachineResourceState(key, resource)
		c.recordResourceReading(c.machineHealth.resourceStates, key, ResourceConfig{Name: resource.Name, Type: resource.Type},
			judgeBattery(battery, machineHealth.BatteryLowChargeThresholdPercent, sampleIsCurrent, staleNote))
	}
}

func describeRunnerConnection(runnerConnected *bool) string {
	switch {
	case runnerConnected == nil:
		return ""
	case *runnerConnected:
		return ", runner connected"
	default:
		return ", runner not connected"
	}
}

// judgeDrive reads a drive's share used the way df does for disk-root: used
// over used plus free-to-a-user, so the blocks kept back for root count as
// neither.
func judgeDrive(drive machineDrive, thresholdPercent float64, sampleIsCurrent bool, staleNote string) resourceReading {
	usable := drive.UsedBytes + drive.FreeBytes
	if usable == 0 {
		return resourceReading{outcome: resourceReadingFailed, err: fmt.Errorf("drive %s reports no used or free bytes", drive.MountPoint)}
	}
	usagePercent := float64(drive.UsedBytes) / float64(usable) * 100
	detail := fmt.Sprintf("%.1fGB free / %.1fGB total", float64(drive.FreeBytes)/(1<<30), float64(drive.TotalBytes)/(1<<30))
	if drive.Label != "" {
		detail = drive.Label + ": " + detail
	}
	if !sampleIsCurrent {
		return resourceReading{outcome: resourceReadingUnavailable, usagePercent: usagePercent, detail: detail + staleNote}
	}
	return resourceReading{
		outcome:           resourceReadingMeasured,
		usagePercent:      usagePercent,
		detail:            detail,
		thresholdBreached: usagePercent >= thresholdPercent,
		breachDescription: fmt.Sprintf("drive %.1f%% full, threshold %.1f%%", usagePercent, thresholdPercent),
	}
}

// judgeBattery reports a battery's usage_pct as the share of charge used,
// 100 minus the charge, and its threshold as 100 minus the low-charge line.
// That keeps "at or above the threshold is bad" true for every resource, so
// the status page draws a battery the way it draws a drive. Only a battery
// that is discharging can breach: one on mains at 5% is charging back up.
func judgeBattery(battery machineBattery, lowChargeThresholdPercent float64, sampleIsCurrent bool, staleNote string) resourceReading {
	detail := fmt.Sprintf("%.0f%% charge, %s", battery.ChargePercent, strings.ReplaceAll(battery.State, "_", " "))
	if battery.SecondsRemaining != nil && battery.State == machineBatteryDischarging {
		detail += fmt.Sprintf(", %s left", (time.Duration(*battery.SecondsRemaining) * time.Second).Round(time.Minute))
	}
	usagePercent := 100 - battery.ChargePercent
	if !sampleIsCurrent {
		return resourceReading{outcome: resourceReadingUnavailable, usagePercent: usagePercent, detail: detail + staleNote}
	}
	return resourceReading{
		outcome:           resourceReadingMeasured,
		usagePercent:      usagePercent,
		detail:            detail,
		thresholdBreached: battery.State == machineBatteryDischarging && battery.ChargePercent <= lowChargeThresholdPercent,
		breachDescription: fmt.Sprintf("battery at %.0f%% and discharging, threshold %.0f%%", battery.ChargePercent, lowChargeThresholdPercent),
	}
}

// machineResourceStates returns the machine resources sorted by name.
// The caller holds c.mu.
func (c *Checker) machineResourceStates() []ResourceState {
	result := make([]ResourceState, 0, len(c.machineHealth.resourceStates))
	for _, state := range c.machineHealth.resourceStates {
		result = append(result, *state)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}
