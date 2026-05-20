// ============================================================
//  VaultHound Agent — written in Go
//  Binary : /usr/bin/vaulthound-agent
//  Config : /etc/vaulthound/agent.conf
//
//  Default mode : animated progress bar on stdout, logs → file only
//  With --log   : full verbose output to stdout + file
// ============================================================
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const Version = "1.0.0"

type Config struct {
	MasterURL    string
	ServerToken  string
	AgentID      string
	Hostname     string
	ScanInterval int
	ScanImage    string
	ScanRepo     string
	ScanDir      string
	AutoDiscover bool
	Daemon       bool
	Verbose      bool
	LogFile      string
}

const (
	cfgFile = "/etc/vaulthound/agent.conf"
	idFile  = "/etc/vaulthound/.agent-id"
)

// ── Logger ────────────────────────────────────────────────────────────────────
var (
	fileLog        *log.Logger
	verbose        bool
	logMu          sync.Mutex
	progressActive bool
)

func initLogger(path string, isVerbose bool) {
	verbose = isVerbose
	os.MkdirAll(filepath.Dir(path), 0755)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		fileLog = log.New(os.Stderr, "", log.LstdFlags)
		return
	}
	fileLog = log.New(f, "", log.LstdFlags)
}

// logf: always writes to file; writes to stdout only when --log is set
func logf(format string, args ...interface{}) {
	fileLog.Printf(format, args...)
	if verbose {
		logMu.Lock()
		if progressActive {
			fmt.Fprint(os.Stdout, "\r\033[K")
		}
		logMu.Unlock()
		fmt.Printf(format+"\n", args...)
	}
}

// ── Progress bar ──────────────────────────────────────────────────────────────
const barWidth = 38

type Progress struct {
	label string
	pct   int
	mu    sync.Mutex
}

func newProgress(label string) *Progress {
	p := &Progress{label: label}
	if !verbose {
		p.render(0)
	}
	return p
}

func (p *Progress) render(pct int) {
	if verbose {
		return
	}
	filled := pct * barWidth / 100
	bar := strings.Repeat("█", filled) + strings.Repeat("░", barWidth-filled)
	logMu.Lock()
	progressActive = true
	fmt.Fprintf(os.Stdout, "\r  \033[36m%-28s\033[0m [%s] \033[33m%3d%%\033[0m",
		truncate(p.label, 28), bar, pct)
	logMu.Unlock()
}

func (p *Progress) Set(pct int) {
	p.mu.Lock()
	p.pct = pct
	p.mu.Unlock()
	p.render(pct)
}

// Pulse smoothly animates 0→85% while Trivy is running
func (p *Progress) Pulse(done <-chan struct{}) {
	if verbose {
		return
	}
	steps := []struct {
		pct   int
		delay time.Duration
	}{
		{3, 200 * time.Millisecond},
		{8, 400 * time.Millisecond},
		{15, 600 * time.Millisecond},
		{24, 800 * time.Millisecond},
		{33, 1 * time.Second},
		{42, 1200 * time.Millisecond},
		{51, 1500 * time.Millisecond},
		{59, 2 * time.Second},
		{66, 2 * time.Second},
		{72, 2500 * time.Millisecond},
		{77, 3 * time.Second},
		{81, 3 * time.Second},
		{84, 4 * time.Second},
		{85, 0},
	}
	go func() {
		for _, s := range steps {
			select {
			case <-done:
				return
			case <-time.After(s.delay):
				p.render(s.pct)
			}
		}
		<-done
	}()
}

func (p *Progress) Finish(summary string) {
	if verbose {
		return
	}
	bar := strings.Repeat("█", barWidth)
	logMu.Lock()
	progressActive = false
	fmt.Fprintf(os.Stdout,
		"\r  \033[36m%-28s\033[0m [\033[32m%s\033[0m] \033[32m100%%\033[0m  %s\n",
		truncate(p.label, 28), bar, summary)
	logMu.Unlock()
}

func (p *Progress) Fail(msg string) {
	if verbose {
		return
	}
	logMu.Lock()
	progressActive = false
	fmt.Fprintf(os.Stdout, "\r  \033[36m%-28s\033[0m \033[31m✘ %s\033[0m\n",
		truncate(p.label, 28), truncate(msg, 50))
	logMu.Unlock()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "…" + s[len(s)-(n-1):]
}

// ── Config loader ─────────────────────────────────────────────────────────────
func loadConfig() *Config {
	cfg := &Config{
		ScanInterval: 30,
		LogFile:      "/var/log/vaulthound/agent.log",
	}
	cfg.Hostname, _ = os.Hostname()

	if f, err := os.Open(cfgFile); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			eq := strings.IndexByte(line, '=')
			if eq < 0 {
				continue
			}
			key := strings.TrimSpace(line[:eq])
			val := strings.TrimSpace(line[eq+1:])
			switch key {
			case "MASTER_URL":    cfg.MasterURL = val
			case "SERVER_TOKEN":  cfg.ServerToken = val
			case "SCAN_INTERVAL": if n, e := strconv.Atoi(val); e == nil { cfg.ScanInterval = n }
			case "SCAN_IMAGE":    cfg.ScanImage = val
			case "SCAN_REPO":     cfg.ScanRepo = val
			case "SCAN_DIR":      cfg.ScanDir = val
			case "AUTO_DISCOVER": cfg.AutoDiscover = strings.EqualFold(val, "true") || val == "1"
			case "DAEMON":        cfg.Daemon = strings.EqualFold(val, "true") || val == "1"
			}
		}
	}

	args := os.Args[1:]
	daemonExplicit := false
	targetOnCLI    := false

	for i := 0; i < len(args); i++ {
		a := args[i]
		next := func() string {
			if i+1 < len(args) {
				i++
				return args[i]
			}
			return ""
		}
		switch a {
		case "--master":     cfg.MasterURL = next()
		case "--token":      cfg.ServerToken = next()
		case "--image":      cfg.ScanImage = next();  targetOnCLI = true
		case "--repo":       cfg.ScanRepo = next();   targetOnCLI = true
		case "--dir":        cfg.ScanDir = next();    targetOnCLI = true
		case "--auto":       cfg.AutoDiscover = true; targetOnCLI = true
		case "--interval":   if n, e := strconv.Atoi(next()); e == nil { cfg.ScanInterval = n }
		case "--daemon":     cfg.Daemon = true;       daemonExplicit = true
		case "--log":        cfg.Verbose = true
		case "--version":    fmt.Printf("vaulthound-agent %s\n", Version); os.Exit(0)
		case "--help", "-h": printHelp(); os.Exit(0)
		}
	}

	// If a scan target was given on CLI without an explicit --daemon,
	// treat this as a one-shot run regardless of DAEMON=true in config.
	if targetOnCLI && !daemonExplicit {
		cfg.Daemon = false
	}

	if data, err := os.ReadFile(idFile); err == nil {
		cfg.AgentID = strings.TrimSpace(string(data))
	}
	return cfg
}

func printHelp() {
	fmt.Printf(`vaulthound-agent %s — Scan. Detect. Protect.

Usage:
  vaulthound-agent [flags]

Flags:
  --master   <url>   Master server URL (overrides config)
  --token    <token> Auth token (overrides config)
  --image    <ref>   Docker image or container name to scan
  --repo     <url>   Git repository URL to scan
  --dir      <path>  Filesystem path to scan
  --auto             Auto-discover all running Docker containers
  --daemon           Run continuously on a schedule
  --interval <min>   Minutes between daemon cycles (default: 30)
  --log              Show verbose output (default: progress bar only)
  --version          Print version and exit
  --help             Show this help

Config file: %s
Log file:    /var/log/vaulthound/agent.log
`, Version, cfgFile)
}

// ── Trivy types & runner ──────────────────────────────────────────────────────
type TrivyReport struct {
	Results []TrivyResult `json:"Results"`
}
type TrivyResult struct {
	Target            string           `json:"Target"`
	Type              string           `json:"Type"`
	Vulnerabilities   []TrivyVuln      `json:"Vulnerabilities"`
	Secrets           []TrivySecret    `json:"Secrets"`
	Misconfigurations []TrivyMisconfig `json:"Misconfigurations"`
}
type TrivyVuln struct {
	VulnerabilityID  string `json:"VulnerabilityID"`
	PkgName          string `json:"PkgName"`
	InstalledVersion string `json:"InstalledVersion"`
	FixedVersion     string `json:"FixedVersion"`
	Severity         string `json:"Severity"`
	Title            string `json:"Title"`
}
type TrivySecret struct {
	RuleID    string `json:"RuleID"`
	Category  string `json:"Category"`
	Title     string `json:"Title"`
	Severity  string `json:"Severity"`
	StartLine int    `json:"StartLine"`
	EndLine   int    `json:"EndLine"`
}
type TrivyMisconfig struct {
	ID       string `json:"ID"`
	Type     string `json:"Type"`
	Title    string `json:"Title"`
	Severity string `json:"Severity"`
	Status   string `json:"Status"`
}

// ScanSummary — camelCase JSON tags to match what master db.js and dashboard expect
type ScanSummary struct {
	CriticalCount  int `json:"criticalCount"`
	HighCount      int `json:"highCount"`
	MediumCount    int `json:"mediumCount"`
	LowCount       int `json:"lowCount"`
	UnknownCount   int `json:"unknownCount"`
	VulnCount      int `json:"vulnCount"`
	SecretCount    int `json:"secretCount"`
	MisconfigCount int `json:"misconfigCount"`
	Targets        int `json:"targets"`
}

type ScanResult struct {
	ScanType    string       `json:"scanType"`
	Target      string       `json:"target"`
	TrivyReport *TrivyReport `json:"trivyReport"`
	Summary     ScanSummary  `json:"summary"`
}

func runTrivy(args []string) (*TrivyReport, error) {
	full := append(args, "--format", "json", "--timeout", "10m", "--no-progress")
	logf("[TRIVY] trivy %s", strings.Join(full, " "))

	cmd := exec.Command("trivy", full...)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb

	if err := cmd.Run(); err != nil {
		if ex, ok := err.(*exec.ExitError); ok && ex.ExitCode() == 1 {
			// exit 1 = findings found — JSON is still valid
		} else {
			return nil, fmt.Errorf("exit %v: %s", err, errb.String())
		}
	}

	raw := out.Bytes()
	if i := bytes.IndexByte(raw, '{'); i > 0 {
		raw = raw[i:]
	}
	var r TrivyReport
	if err := json.Unmarshal(raw, &r); err != nil {
		return nil, fmt.Errorf("JSON: %v", err)
	}
	return &r, nil
}

func summarise(r *TrivyReport) ScanSummary {
	var s ScanSummary
	s.Targets = len(r.Results)
	add := func(sv string) {
		switch strings.ToUpper(sv) {
		case "CRITICAL": s.CriticalCount++
		case "HIGH":     s.HighCount++
		case "MEDIUM":   s.MediumCount++
		case "LOW":      s.LowCount++
		default:         s.UnknownCount++
		}
	}
	for _, res := range r.Results {
		for _, v := range res.Vulnerabilities   { s.VulnCount++;      add(v.Severity)   }
		for _, sc := range res.Secrets          { s.SecretCount++;    add(sc.Severity)  }
		for _, mc := range res.Misconfigurations { s.MisconfigCount++; add(mc.Severity) }
	}
	return s
}

// ── Scan helpers ──────────────────────────────────────────────────────────────
func resolveImage(ref string) string {
	if out, err := exec.Command("docker", "inspect",
		"--format", "{{.Config.Image}}", ref).Output(); err == nil {
		if img := strings.TrimSpace(string(out)); img != "" {
			return img
		}
	}
	return ref
}

type container struct{ ID, Image, Name string }

func listContainers() []container {
	out, err := exec.Command("docker", "ps",
		"--format", "{{.ID}}|{{.Image}}|{{.Names}}").Output()
	if err != nil {
		return nil
	}
	var cs []container
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		p := strings.SplitN(line, "|", 3)
		if len(p) == 3 {
			cs = append(cs, container{p[0], p[1], p[2]})
		}
	}
	return cs
}

func doScan(scanType, target string, trivyArgs []string, prog *Progress) (*ScanResult, error) {
	done := make(chan struct{})
	go prog.Pulse(done)

	report, err := runTrivy(trivyArgs)
	close(done)
	time.Sleep(30 * time.Millisecond) // let pulse goroutine exit cleanly

	if err != nil {
		return nil, err
	}
	prog.Set(92)
	return &ScanResult{
		ScanType: scanType, Target: target,
		TrivyReport: report, Summary: summarise(report),
	}, nil
}

// ── Reporter ──────────────────────────────────────────────────────────────────
type ingestPayload struct {
	Agent    agentInfo         `json:"agent"`
	ScanType string            `json:"scanType"`
	Target   string            `json:"target"`
	Report   interface{}       `json:"trivyReport"`
	Summary  ScanSummary       `json:"summary"`
	Metadata map[string]string `json:"metadata"`
}
type agentInfo struct {
	AgentID      string `json:"agentId"`
	Hostname     string `json:"hostname"`
	OS           string `json:"os"`
	AgentVersion string `json:"agentVersion"`
}
type ingestResponse struct {
	OK          bool   `json:"ok"`
	Overwritten bool   `json:"overwritten"`
	ScanID      string `json:"scanId"`
	AgentID     string `json:"agentId"`
}

func send(cfg *Config, result *ScanResult, prog *Progress) error {
	// ── Validate master URL ───────────────────────────────────────────────────
	masterURL := strings.TrimRight(cfg.MasterURL, "/")
	if masterURL == "" {
		return fmt.Errorf("MASTER_URL is not set in %s", cfgFile)
	}
	if !strings.HasPrefix(masterURL, "http://") && !strings.HasPrefix(masterURL, "https://") {
		masterURL = "http://" + masterURL
		logf("[WARN] MASTER_URL had no scheme — using http://: %s", masterURL)
	}

	payload := ingestPayload{
		Agent: agentInfo{
			AgentID: cfg.AgentID, Hostname: cfg.Hostname,
			OS:           fmt.Sprintf("%s/%s", runtime.GOOS, runtime.GOARCH),
			AgentVersion: Version,
		},
		ScanType: result.ScanType, Target: result.Target,
		Report:   result.TrivyReport, Summary: result.Summary,
		Metadata: map[string]string{"scannedAt": time.Now().UTC().Format(time.RFC3339)},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal payload: %v", err)
	}

	ingestURL := masterURL + "/api/ingest"
	logf("[REPORT] → %s", ingestURL)

	// ── Build request — handle error explicitly (never ignore) ────────────────
	req, err := http.NewRequest("POST", ingestURL, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build request (check MASTER_URL %q): %v", masterURL, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.ServerToken)

	// ── Send ──────────────────────────────────────────────────────────────────
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return fmt.Errorf("connect to %s: %v", masterURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 401 {
		return fmt.Errorf("authentication failed (401) — check SERVER_TOKEN in %s", cfgFile)
	}
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("master returned %d: %s", resp.StatusCode, string(b))
	}

	var ir ingestResponse
	if decErr := json.NewDecoder(resp.Body).Decode(&ir); decErr != nil {
		logf("[WARN] Could not decode master response: %v", decErr)
	}

	action := "Sent"
	if ir.Overwritten {
		action = "Updated"
	}
	logf("[REPORT] ✔ %s  scanId=%s", action, ir.ScanID)

	// Persist agent ID assigned by master
	if ir.AgentID != "" && ir.AgentID != cfg.AgentID {
		cfg.AgentID = ir.AgentID
		os.MkdirAll(filepath.Dir(idFile), 0755)
		os.WriteFile(idFile, []byte(ir.AgentID), 0640)
	}

	// Build compact result line for non-verbose mode
	sm := result.Summary
	summary := fmt.Sprintf(
		"C:\033[31m%d\033[0m H:\033[33m%d\033[0m M:\033[93m%d\033[0m S:\033[35m%d\033[0m  \033[32m%s ✔\033[0m",
		sm.CriticalCount, sm.HighCount, sm.MediumCount, sm.SecretCount, action)
	prog.Finish(summary)
	return nil
}

// ── Scan cycle ────────────────────────────────────────────────────────────────
func runCycle(cfg *Config) {
	logf("[CYCLE] Start %s", time.Now().Format(time.RFC3339))

	type task struct{ kind, ref string }
	var tasks []task

	if cfg.ScanImage != "" { tasks = append(tasks, task{"image", cfg.ScanImage}) }
	if cfg.ScanRepo  != "" { tasks = append(tasks, task{"repo",  cfg.ScanRepo})  }
	if cfg.ScanDir   != "" { tasks = append(tasks, task{"dir",   cfg.ScanDir})   }

	if cfg.AutoDiscover {
		seen := map[string]bool{}
		for _, c := range listContainers() {
			if !seen[c.Image] {
				seen[c.Image] = true
				tasks = append(tasks, task{"image", c.Image})
				logf("[AUTO] %s → %s", c.Name, c.Image)
			}
		}
	}

	if len(tasks) == 0 {
		fmt.Println("  \033[33m⚠ Nothing to scan.\033[0m Use --image / --repo / --dir / --auto")
		return
	}

	if !verbose {
		// Print compact header
		fmt.Printf("\n  \033[1;36mVaultHound\033[0m \033[36mv%s\033[0m  %s → \033[33m%s\033[0m\n\n",
			Version, cfg.Hostname, cfg.MasterURL)
		fmt.Printf("  \033[90m%-28s  %-38s  %s\033[0m\n",
			"Target", strings.Repeat("─", 38), "Result")
		fmt.Println()
	}

	for _, t := range tasks {
		logf("[SCAN] %s: %s", t.kind, t.ref)

		prog := newProgress(t.ref)

		var result *ScanResult
		var err error
		switch t.kind {
		case "image":
			img := resolveImage(t.ref)
			result, err = doScan("image", img,
				[]string{"image", "--scanners", "vuln,secret", img}, prog)
		case "repo":
			result, err = doScan("repo", t.ref,
				[]string{"repository", "--scanners", "vuln,secret,misconfig", t.ref}, prog)
		case "dir":
			result, err = doScan("filesystem", t.ref,
				[]string{"filesystem", "--scanners", "vuln,secret,misconfig", t.ref}, prog)
		}

		if err != nil {
			prog.Fail(err.Error())
			logf("[ERROR] %s: %v", t.ref, err)
			continue
		}

		if err := send(cfg, result, prog); err != nil {
			prog.Fail(err.Error())
			logf("[ERROR] send %s: %v", t.ref, err)
		}
	}

	logf("[CYCLE] Done %s", time.Now().Format(time.RFC3339))

	if !verbose {
		fmt.Println()
	}
}

// ── Main ──────────────────────────────────────────────────────────────────────
func main() {
	cfg := loadConfig()
	initLogger(cfg.LogFile, cfg.Verbose)

	if cfg.MasterURL == "" {
		fmt.Fprintln(os.Stderr, "Error: MASTER_URL not set. Edit "+cfgFile+" or use --master")
		os.Exit(1)
	}
	// Auto-add http:// if scheme is missing
	if !strings.HasPrefix(cfg.MasterURL, "http://") && !strings.HasPrefix(cfg.MasterURL, "https://") {
		cfg.MasterURL = "http://" + cfg.MasterURL
	}

	// Trivy check — silent in non-verbose mode
	if out, err := exec.Command("trivy", "--version").Output(); err != nil {
		fmt.Fprintln(os.Stderr, "Error: Trivy not found. Run install-agent.sh first.")
		os.Exit(1)
	} else {
		logf("[OK] %s", strings.TrimSpace(strings.Split(string(out), "\n")[0]))
	}

	if cfg.Daemon {
		if !verbose {
			fmt.Printf("\033[36m  Daemon mode — every %d min  (Ctrl+C to stop)\033[0m\n",
				cfg.ScanInterval)
		} else {
			logf("[DAEMON] Scanning every %d min", cfg.ScanInterval)
		}
		runCycle(cfg)
		ticker := time.NewTicker(time.Duration(cfg.ScanInterval) * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			runCycle(cfg)
		}
	} else {
		// One-shot: run and exit
		runCycle(cfg)
		os.Exit(0)
	}
}
