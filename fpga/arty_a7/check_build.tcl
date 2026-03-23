## Ostomachion — standalone quality gate check script
## Runs against an already-built project; no re-synthesis.
## Usage: vivado -mode batch -source fpga/arty_a7/check_build.tcl

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize "$script_dir/../.."]
set build_dir  "$proj_root/build/arty_a7"
set xpr        "$build_dir/vivado_project/ostomachion_arty_a7.xpr"

if {![file exists $xpr]} {
    puts "ERROR: No built project found at $xpr"
    puts "ERROR: Run 'make fpga-synth' first."
    exit 1
}

open_project $xpr
open_run impl_1

# ---------------------------------------------------------------------------
# 1. Timing closure — query via get_timing_paths (works on opened runs)
# ---------------------------------------------------------------------------
set setup_path [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
set hold_path  [get_timing_paths -max_paths 1 -nworst 1 -hold  -quiet]

set wns ""
set whs ""
if {$setup_path ne ""} { set wns [get_property SLACK $setup_path] }
if {$hold_path  ne ""} { set whs [get_property SLACK $hold_path]  }

# ---------------------------------------------------------------------------
# 2. Resource utilisation — parse report_utilization output
# ---------------------------------------------------------------------------
set util_rpt [report_utilization -return_string -quiet]

proc parse_util_pct {rpt keyword} {
    foreach line [split $rpt "\n"] {
        if {[string match "*${keyword}*" $line]} {
            # Table columns: | Name | Used | Fixed | Prohibited | Available | Util% |
            if {[regexp {\|\s*([\d.]+)\s*\|[^|]*\|[^|]*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|} $line -> used avail pct]} {
                return [list $used $avail $pct]
            }
        }
    }
    return [list "?" "?" "?"]
}

set lut_info  [parse_util_pct $util_rpt "Slice LUTs"]
set reg_info  [parse_util_pct $util_rpt "Slice Registers"]
set bram_info [parse_util_pct $util_rpt "Block RAM Tile"]
set io_info   [parse_util_pct $util_rpt "Bonded IOB"]

# ---------------------------------------------------------------------------
# 3. Report
# ---------------------------------------------------------------------------
puts ""
puts "INFO: ============================================================"
puts "INFO:  Ostomachion Arty A7 — Build Quality Report"
puts "INFO: ============================================================"
puts "INFO:  Timing (100 MHz constraint)"
puts "INFO:    WNS (worst setup slack) : ${wns} ns"
puts "INFO:    WHS (worst hold  slack) : ${whs} ns"
puts "INFO:  Utilisation (XC7A100T)"
puts "INFO:    Slice LUTs    : [lindex $lut_info  0] / [lindex $lut_info  1]  ([lindex $lut_info  2]%)"
puts "INFO:    Slice Regs    : [lindex $reg_info  0] / [lindex $reg_info  1]  ([lindex $reg_info  2]%)"
puts "INFO:    Block RAMs    : [lindex $bram_info 0] / [lindex $bram_info 1]  ([lindex $bram_info 2]%)"
puts "INFO:    Bonded IOBs   : [lindex $io_info   0] / [lindex $io_info   1]  ([lindex $io_info   2]%)"
puts "INFO: ============================================================"

set pass 1

# Gate 1: setup timing
if {$wns eq "" || [expr {$wns < 0}]} {
    puts "FAIL: Setup timing VIOLATED — WNS = $wns ns  (must be >= 0)"
    set pass 0
} else {
    puts "PASS: Setup timing met       — WNS = +$wns ns"
}

# Gate 2: hold timing
if {$whs eq "" || [expr {$whs < 0}]} {
    puts "FAIL: Hold timing VIOLATED   — WHS = $whs ns  (must be >= 0)"
    set pass 0
} else {
    puts "PASS: Hold timing met        — WHS = +$whs ns"
}

# Gate 3: LUT headroom (warn at >80%, fail at >95%)
set lut_pct [lindex $lut_info 2]
if {$lut_pct ne "?" && $lut_pct > 95} {
    puts "FAIL: LUT utilisation ${lut_pct}% critically high (>95%) — routing will likely fail"
    set pass 0
} elseif {$lut_pct ne "?" && $lut_pct > 80} {
    puts "WARN: LUT utilisation ${lut_pct}% high (>80%) — routing congestion risk"
} else {
    puts "PASS: LUT utilisation ${lut_pct}% within safe threshold"
}

# Gate 4: BRAM headroom (warn at >85%, fail at >95%)
set bram_pct [lindex $bram_info 2]
if {$bram_pct ne "?" && $bram_pct > 95} {
    puts "FAIL: BRAM utilisation ${bram_pct}% critically high (>95%)"
    set pass 0
} elseif {$bram_pct ne "?" && $bram_pct > 85} {
    puts "WARN: BRAM utilisation ${bram_pct}% high (>85%)"
} else {
    puts "PASS: BRAM utilisation ${bram_pct}% within safe threshold"
}

# Gate 5: DRC — any ERROR-level DRC violation blocks deployment
set drc_str [report_drc -return_string -quiet]
if {[regexp {ERROR} $drc_str]} {
    puts "FAIL: DRC violations present — run report_drc for details"
    set pass 0
} else {
    puts "PASS: DRC clean — no error-level violations"
}

puts "INFO: ============================================================"
if {$pass} {
    puts "INFO:  RESULT: ALL QUALITY GATES PASSED"
} else {
    puts "ERROR: RESULT: QUALITY GATES FAILED — bitstream should not be deployed"
}
puts "INFO: ============================================================"

if {!$pass} { exit 1 }
