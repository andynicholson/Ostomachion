## Ostomachion — standalone quality gate check script (XEM7310-A200)
## Runs against an already-built project; no re-synthesis.
## Usage: vivado -mode batch -source fpga/xem7310/check_build.tcl

set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize "$script_dir/../.."]
set build_dir  "$proj_root/build/xem7310"
set xpr        "$build_dir/vivado_project/ostomachion_xem7310.xpr"

set dcp "$build_dir/impl_final.dcp"

if {![file exists $dcp]} {
    puts "ERROR: No implementation checkpoint found at $dcp"
    puts "ERROR: Run 'make fpga-synth' first."
    exit 1
}

open_checkpoint $dcp

# ---------------------------------------------------------------------------
# 1. Timing closure
# ---------------------------------------------------------------------------
set setup_path [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
set hold_path  [get_timing_paths -max_paths 1 -nworst 1 -hold  -quiet]

set wns ""
set whs ""
if {$setup_path ne ""} { set wns [get_property SLACK $setup_path] }
if {$hold_path  ne ""} { set whs [get_property SLACK $hold_path]  }

# ---------------------------------------------------------------------------
# 2. Resource utilisation
# ---------------------------------------------------------------------------
set util_rpt [report_utilization -return_string -quiet]

proc parse_util_pct {rpt keyword} {
    foreach line [split $rpt "\n"] {
        if {[string match "*${keyword}*" $line]} {
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
puts "INFO:  Ostomachion XEM7310-A200 — Build Quality Report"
puts "INFO: ============================================================"
puts "INFO:  Timing (100 MHz constraint)"
puts "INFO:    WNS (worst setup slack) : ${wns} ns"
puts "INFO:    WHS (worst hold  slack) : ${whs} ns"
puts "INFO:  Utilisation (XC7A200T)"
puts "INFO:    Slice LUTs    : [lindex $lut_info  0] / [lindex $lut_info  1]  ([lindex $lut_info  2]%)"
puts "INFO:    Slice Regs    : [lindex $reg_info  0] / [lindex $reg_info  1]  ([lindex $reg_info  2]%)"
puts "INFO:    Block RAMs    : [lindex $bram_info 0] / [lindex $bram_info 1]  ([lindex $bram_info 2]%)"
puts "INFO:    Bonded IOBs   : [lindex $io_info   0] / [lindex $io_info   1]  ([lindex $io_info   2]%)"
puts "INFO: ============================================================"

set pass 1

if {$wns eq "" || [expr {$wns < 0}]} {
    puts "FAIL: Setup timing VIOLATED — WNS = $wns ns  (must be >= 0)"
    set pass 0
} else {
    puts "PASS: Setup timing met       — WNS = +$wns ns"
}

if {$whs eq "" || [expr {$whs < 0}]} {
    puts "FAIL: Hold timing VIOLATED   — WHS = $whs ns  (must be >= 0)"
    set pass 0
} else {
    puts "PASS: Hold timing met        — WHS = +$whs ns"
}

# WNS/WHS only describe CONSTRAINED paths; a design with unconstrained
# endpoints can show positive slack yet contain untimed logic.  Fail if any
# endpoint has no clock / no required time.  (report_timing_summary writes
# the detail; here we count via check_timings unconstrained categories.)
set ct [check_timing -quiet -return_string -override_defaults {no_clock unconstrained_internal_endpoints no_input_delay no_output_delay}]
set unconstrained 0
foreach pat {{There are ([0-9]+) register/latch pins with no clock}
             {There are ([0-9]+) pins that are not constrained for maximum delay}} {
    if {[regexp $pat $ct -> n] && $n > 0} { incr unconstrained $n }
}
if {$unconstrained > 0} {
    puts "WARN: $unconstrained unconstrained timing endpoint(s) — slack numbers"
    puts "      above do not cover them; review check_timing output."
    # Treated as a warning (the FrontPanel okHost IP intentionally leaves
    # some internal pins unconstrained); promote to FAIL here if the design
    # should have zero unconstrained endpoints.
} else {
    puts "PASS: no unconstrained timing endpoints"
}

set lut_pct [lindex $lut_info 2]
if {$lut_pct ne "?" && $lut_pct > 95} {
    puts "FAIL: LUT utilisation ${lut_pct}% critically high (>95%) — routing will likely fail"
    set pass 0
} elseif {$lut_pct ne "?" && $lut_pct > 80} {
    puts "WARN: LUT utilisation ${lut_pct}% high (>80%) — routing congestion risk"
} else {
    puts "PASS: LUT utilisation ${lut_pct}% within safe threshold"
}

set bram_pct [lindex $bram_info 2]
if {$bram_pct ne "?" && $bram_pct > 95} {
    puts "FAIL: BRAM utilisation ${bram_pct}% critically high (>95%)"
    set pass 0
} elseif {$bram_pct ne "?" && $bram_pct > 85} {
    puts "WARN: BRAM utilisation ${bram_pct}% high (>85%)"
} else {
    puts "PASS: BRAM utilisation ${bram_pct}% within safe threshold"
}

# Query DRC by severity via the proper API rather than grepping the report
# text for the substring "ERROR" (which false-matches rule names / benign
# lines and misses the structured result).  Count only Error-severity (and
# the more severe Critical) violations.
report_drc -file "$build_dir/drc.rpt" -quiet
set drc_errs [get_drc_violations -quiet -filter {SEVERITY == "Error" || SEVERITY =~ "*Critical*"}]
set drc_n [llength $drc_errs]
if {$drc_n > 0} {
    puts "FAIL: $drc_n DRC error-severity violation(s) — see $build_dir/drc.rpt"
    foreach v [lrange $drc_errs 0 9] {
        puts "        [get_property SEVERITY $v] [get_property RULE $v]: $v"
    }
    set pass 0
} else {
    puts "PASS: DRC clean — no error-severity violations"
}

puts "INFO: ============================================================"
if {$pass} {
    puts "INFO:  RESULT: ALL QUALITY GATES PASSED"
} else {
    puts "ERROR: RESULT: QUALITY GATES FAILED — bitstream should not be deployed"
}
puts "INFO: ============================================================"

if {!$pass} { exit 1 }
