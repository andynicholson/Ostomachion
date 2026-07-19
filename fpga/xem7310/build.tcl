## Ostomachion — Vivado non-interactive build script (XEM7310-A200)
## Usage: vivado -mode batch -source fpga/xem7310/build.tcl
##   Normal production build:
##     vivado -mode batch -source fpga/xem7310/build.tcl
##   Debug build with ILA probes:
##     vivado -mode batch -source fpga/xem7310/build.tcl -tclargs debug
##
## Produces:
##   build/xem7310/ostomachion_xem7310.bit        (production bitstream)
##   build/xem7310/ostomachion_xem7310.mcs        (SPI flash image)
##   build/xem7310/ostomachion_xem7310_debug.bit  (ILA debug, if -tclargs debug)
##   build/xem7310/build_id.txt                   (version + git hash)
##   build/xem7310/timing_summary.rpt             (setup/hold analysis)
##   build/xem7310/utilization.rpt                (LUT/BRAM/IO counts)
##   build/xem7310/drc.rpt                        (design rule violations)

set DEBUG_BUILD 0
if {[llength $argv] > 0 && [lindex $argv 0] eq "debug"} {
    set DEBUG_BUILD 1
    puts "INFO: ══ DEBUG BUILD — ILA probes will be inserted ══"
}

# ---------------------------------------------------------------------------
# Resolve project root and output directory
# ---------------------------------------------------------------------------
set script_dir  [file dirname [file normalize [info script]]]
set proj_root   [file normalize "$script_dir/../.."]
set build_dir   "$proj_root/build/xem7310"
set neorv32_rtl "$proj_root/neorv32/rtl/core"
set fpga_dir    "$proj_root/fpga/xem7310"

file mkdir $build_dir

puts "INFO: Project root : $proj_root"
puts "INFO: Build output : $build_dir"

# ---------------------------------------------------------------------------
# Create Vivado project — xc7a200tfbg484-1 (Opal Kelly XEM7310-A200)
# ---------------------------------------------------------------------------
create_project ostomachion_xem7310 "$build_dir/vivado_project" \
    -part xc7a200tfbg484-1 -force

set_property TARGET_LANGUAGE VHDL [current_project]

# ---------------------------------------------------------------------------
# Add NEORV32 core sources (library neorv32)
# ---------------------------------------------------------------------------
set soc_files [lsort [glob "$neorv32_rtl/*.vhd"]]
puts "INFO: Found [llength $soc_files] NEORV32 core files in $neorv32_rtl"

add_files -fileset sources_1 $soc_files
foreach f $soc_files {
    set_property LIBRARY neorv32 [get_files $f]
}

# ---------------------------------------------------------------------------
# Add upstream NEORV32 XBUS-to-AXI4 bridge (library work)
# ---------------------------------------------------------------------------
set bridge_rtl "$proj_root/neorv32/rtl/system_integration/xbus2axi4_bridge.vhd"

add_files -fileset sources_1 [list $bridge_rtl]

# ---------------------------------------------------------------------------
# Add board-level top and UART bridge (library work)
# ---------------------------------------------------------------------------
add_files -fileset sources_1 [list \
    "$fpga_dir/xem7310_top.vhd"  \
    "$fpga_dir/fp_uart_bridge.vhd" \
    "$fpga_dir/fp_fft_pipe_bridge.vhd" \
    "$fpga_dir/fft_beat_counter.vhd" \
    "$fpga_dir/cmpy_normalizer.vhd" \
    "$fpga_dir/spectral_filter.vhd" \
]
set_property TOP xem7310_top [get_filesets sources_1]

# ---------------------------------------------------------------------------
# FrontPanel HDL library (Opal Kelly SDK)
# The SDK ships okLibrary.vhd (component declarations) and Verilog endpoint
# modules under FrontPanelHDL/<board>/Vivado-<year>/.
# Set FRONTPANEL_DIR to the SDK root before running this script.
# FrontPanel host-interface pin constraints are in xem7310.xdc (not from SDK).
# ---------------------------------------------------------------------------
set fp_dir ""
if {[info exists ::env(FRONTPANEL_DIR)]} {
    set fp_dir $::env(FRONTPANEL_DIR)
} elseif {[info exists ::env(OKFP_SDK)]} {
    set fp_dir $::env(OKFP_SDK)
}

if {$fp_dir eq ""} {
    puts "ERROR: FRONTPANEL_DIR environment variable not set."
    puts "       Set it to the Opal Kelly FrontPanel SDK installation root."
    puts "       Example: export FRONTPANEL_DIR=/opt/FrontPanel"
    exit 1
}

# Locate the HDL sources — SDK layout: FrontPanelHDL/<board>/Vivado-<year>/
set fp_hdl ""
foreach board [list "XEM7310-A200" "XEM7310"] {
    foreach vdir [lsort -decreasing [glob -nocomplain "$fp_dir/FrontPanelHDL/$board/Vivado-*"]] {
        if {[file exists "$vdir/okLibrary.vhd"]} {
            set fp_hdl $vdir
            break
        }
    }
    if {$fp_hdl ne ""} { break }
}

if {$fp_hdl eq ""} {
    puts "ERROR: okLibrary.vhd not found under $fp_dir/FrontPanelHDL/XEM7310-A200/"
    puts "       Expected layout: FrontPanelHDL/XEM7310-A200/Vivado-<year>/okLibrary.vhd"
    puts "       Ensure the FrontPanel SDK is installed correctly."
    exit 1
}
puts "INFO: FrontPanel HDL : $fp_hdl"

# Add VHDL library (component declarations) and all Verilog sources
add_files -fileset sources_1 [glob "$fp_hdl/*.vhd"]
add_files -fileset sources_1 [glob "$fp_hdl/*.v"]

# ---------------------------------------------------------------------------
# Create the IP Integrator block design
# ---------------------------------------------------------------------------
puts "INFO: Creating IP Integrator block design..."
source "$fpga_dir/ostomachion_bd.tcl"

# ---------------------------------------------------------------------------
# Add XDC constraints
# ---------------------------------------------------------------------------
add_files -fileset constrs_1 "$fpga_dir/xem7310.xdc"

# ---------------------------------------------------------------------------
# Set VHDL-2008 for NEORV32 core files and custom RTL only.
# ---------------------------------------------------------------------------
set rtl_vhdl2008_files [concat $soc_files [list \
    $bridge_rtl                            \
    "$fpga_dir/xem7310_top.vhd"           \
    "$fpga_dir/fp_uart_bridge.vhd"        \
    "$fpga_dir/fp_fft_pipe_bridge.vhd"    \
    "$fpga_dir/fft_beat_counter.vhd"      \
    "$fpga_dir/cmpy_normalizer.vhd"       \
    "$fpga_dir/spectral_filter.vhd"       \
]]
foreach f $rtl_vhdl2008_files {
    set_property FILE_TYPE {VHDL 2008} [get_files $f]
}

# ---------------------------------------------------------------------------
# Synthesis
# ---------------------------------------------------------------------------
puts "INFO: ── Synthesis (launch_runs) ───────────────────────────────────────"
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: Synthesis did not complete — see:"
    puts "  $build_dir/vivado_project/ostomachion_xem7310.runs/synth_1/runme.log"
    exit 1
}
# PROGRESS reaches 100% even for a failed run; STATUS is the authoritative indicator.
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    puts "ERROR: Synthesis failed (STATUS=\"$synth_status\") — see:"
    puts "  $build_dir/vivado_project/ostomachion_xem7310.runs/synth_1/runme.log"
    exit 1
}
puts "INFO: Synthesis complete (STATUS=\"$synth_status\")."

open_run synth_1 -name synth_1

# ---------------------------------------------------------------------------
# Implementation
# ---------------------------------------------------------------------------
puts "INFO: ── Optimisation ───────────────────────────────────────────────────"
opt_design -verbose

puts "INFO: ── Placement ──────────────────────────────────────────────────────"
place_design -verbose

puts "INFO: ── Physical optimisation (post-place) ─────────────────────────────"
phys_opt_design -verbose

puts "INFO: ── Routing ────────────────────────────────────────────────────────"
route_design -verbose

puts "INFO: ── Physical optimisation (post-route) ───────────────────────────"
phys_opt_design -verbose

puts "INFO: ── Save implementation checkpoint ────────────────────────────────"
write_checkpoint -force "$build_dir/impl_final.dcp"
puts "INFO: Checkpoint saved to $build_dir/impl_final.dcp"

# ---------------------------------------------------------------------------
# Optional ILA debug build
# ---------------------------------------------------------------------------
# Probe set captures the xfft output handshake and aresetn release together
# so the AXI-Stream flow can be inspected on running hardware without
# rebuilding the bitstream.  The xfft m_axis_data_tlast bit is the deciding
# signal for any beat-count anomaly investigation (it must rise on the Nth
# output beat after each aresetn pulse — see ACCEL_ARCH.md §5).  The xfft
# aresetn AFTER the AND gate (xfft_rst_and/Res) is included so the trigger
# lines up with the actual pipeline release, not the GPIO write that drives
# it.
#
# Recommended trigger: rising edge of xfft_rst_and/Res, with TVALID & TLAST
# captured in a 1024-sample window.
if {$DEBUG_BUILD} {
    puts "INFO: ── ILA insertion (debug build) ────────────────────────────────"

    set mm2s_nets   [get_nets -hierarchical -filter {NAME =~ *M_AXIS_MM2S*} -quiet]
    set s2mm_nets   [get_nets -hierarchical -filter {NAME =~ *S_AXIS_S2MM*} -quiet]
    set irq_nets    [get_nets -hierarchical -filter {NAME =~ *introut*} -quiet]
    set ovflo_nets  [get_nets -hierarchical -filter {NAME =~ *m_axis_status*} -quiet]
    set xfft_data   [get_nets -hierarchical -filter {NAME =~ *xfft_0*m_axis_data*} -quiet]
    set xfft_rstn   [get_nets -hierarchical -filter {NAME =~ *xfft_rst_and*Res*} -quiet]
    set gpio_out    [get_nets -hierarchical -filter {NAME =~ *axi_gpio_0*gpio_io_o*} -quiet]

    set probe_count 0
    foreach net [concat $mm2s_nets $s2mm_nets $irq_nets $ovflo_nets \
                        $xfft_data $xfft_rstn $gpio_out] {
        set_property MARK_DEBUG true [get_nets $net]
        incr probe_count
    }
    puts "INFO: Marked $probe_count nets for debug capture."

    implement_debug_core
    write_debug_probes -force "$build_dir/debug_probes.ltx"
    puts "INFO: Debug probes written to $build_dir/debug_probes.ltx"

    write_bitstream \
        -force \
        "$build_dir/ostomachion_xem7310_debug.bit"
    puts "INFO: Debug bitstream → $build_dir/ostomachion_xem7310_debug.bit"
    puts "INFO: To inspect the xfft output AXI-Stream live:"
    puts "INFO:   1. make fpga-program BIT_FILE=$build_dir/ostomachion_xem7310_debug.bit"
    puts "INFO:   2. Open Vivado Hardware Manager, load $build_dir/debug_probes.ltx"
    puts "INFO:   3. Trigger on rising edge of xfft_rst_and/Res"
    puts "INFO:   4. Inspect xfft_0/m_axis_data_tvalid and m_axis_data_tlast"
    puts "INFO:      after aresetn deasserts but before MM2S starts."
}

# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------
report_timing_summary \
    -max_paths 10 \
    -report_unconstrained \
    -file "$build_dir/timing_summary.rpt" \
    -warn_on_violation

report_utilization \
    -file "$build_dir/utilization.rpt"

report_drc \
    -file "$build_dir/drc.rpt"

# Severity-aware DRC gate: count Error/Critical violations via the API rather
# than grepping the report text for the substring "ERROR" (which false-
# matches rule names and benign lines).
set drc_errs [get_drc_violations -quiet -filter {SEVERITY == "Error" || SEVERITY =~ "*Critical*"}]
if {[llength $drc_errs] > 0} {
    puts "ERROR: [llength $drc_errs] DRC error-severity violation(s) — see $build_dir/drc.rpt"
    puts "ERROR: Resolve all DRC errors before deploying bitstream."
    exit 1
}
puts "INFO: DRC clean — no error-severity violations found."

# ---------------------------------------------------------------------------
# Build ID
# ---------------------------------------------------------------------------
set git_hash    "unknown"
set git_version "unknown"
set git_commit  ""
catch {
    set git_hash    [string trim [exec git -C $proj_root describe --always --dirty --abbrev=8]]
    set git_version [string trim [exec git -C $proj_root describe --tags --always --dirty --abbrev=8]]
    # Raw commit hash for the USERID — always hex, unlike `describe`, which
    # returns a tag-decorated string (e.g. "v1.0.0-rc1-4-gDEADBEEF") whenever a
    # tag is reachable.  Deriving USERID from `describe` produced non-hex like
    # "0xv1.0.0rc" and failed write_bitstream (BITSTREAM.CONFIG.USERID must be
    # hex).  Use rev-parse so the USERID is well-formed at any tag/describe state.
    set git_commit  [string trim [exec git -C $proj_root rev-parse --short=8 HEAD]]
}
set build_ts  [clock format [clock seconds] -format {%Y%m%d_%H%M%S}]
set build_id  "${git_version} (git: ${git_hash}, built: ${build_ts})"

# Keep only hex digits from the commit hash (defensive: a dirty tree can append
# "-dirty" via other paths), then pad/truncate to the 8-nibble USERID field.
set id_clean [regsub -all {[^0-9a-fA-F]} $git_commit ""]
set id_clean [string range "${id_clean}00000000" 0 7]
set_property BITSTREAM.CONFIG.USERID "0x${id_clean}" [current_design]

set fid [open "$build_dir/build_id.txt" w]
puts $fid $build_id
close $fid
puts "INFO: Build ID : $build_id"
puts "INFO: USERID   : 0x${id_clean}  (readable via JTAG config status register)"

# ---------------------------------------------------------------------------
# Bitstream — USB-programmable (FrontPanel ConfigureFPGA / make fpga-program)
# No CONFIG_MODE override: defaults to SelectMAP which FrontPanel expects.
# ---------------------------------------------------------------------------
puts "INFO: ── Bitstream (USB) ─────────────────────────────────────────────────"
write_bitstream \
    -force \
    -verbose \
    "$build_dir/ostomachion_xem7310.bit"

puts "INFO: USB bitstream → $build_dir/ostomachion_xem7310.bit"

# ---------------------------------------------------------------------------
# Flash bitstream + MCS — for 'make fpga-flash' persistent boot from SPI flash.
# XEM7310-A200 has a 16 MiB FPGA configuration flash (SPIx4).
# The SPI properties must be set AFTER the USB bitstream is written so they
# don't pollute the USB-programmable .bit file (CONFIG_MODE SPIx4 causes
# DoneNotHigh when programmed via FrontPanel USB).
# ---------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4        [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE Yes     [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33         [current_design]
set_property CONFIG_MODE SPIx4                      [current_design]

puts "INFO: ── Bitstream (SPI flash) ───────────────────────────────────────────"
write_bitstream \
    -force \
    "$build_dir/ostomachion_xem7310_flash.bit"

puts "INFO: ── Flash image (MCS) ───────────────────────────────────────────────"
write_cfgmem \
    -format mcs \
    -interface SPIx4 \
    -size 16 \
    -loadbit "up 0x00000000 $build_dir/ostomachion_xem7310_flash.bit" \
    -force \
    "$build_dir/ostomachion_xem7310.mcs"
puts "INFO: Flash image → $build_dir/ostomachion_xem7310.mcs"
puts "INFO: Run 'make fpga-flash' to program the on-board SPI flash."

# ---------------------------------------------------------------------------
# Post-build quality gates
# ---------------------------------------------------------------------------
puts "INFO: Running post-build quality checks..."

set setup_path [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
set hold_path  [get_timing_paths -max_paths 1 -nworst 1 -hold  -quiet]
set wns ""
set whs ""
if {$setup_path ne ""} { set wns [get_property SLACK $setup_path] }
if {$hold_path  ne ""} { set whs [get_property SLACK $hold_path]  }

puts "INFO: Timing — WNS = $wns ns  WHS = $whs ns"

set timing_ok 1
if {$wns eq "" || [expr {$wns < 0}]} {
    puts "ERROR: Setup timing VIOLATED — WNS = $wns ns (must be >= 0)"
    set timing_ok 0
}
if {$whs eq "" || [expr {$whs < 0}]} {
    puts "ERROR: Hold timing VIOLATED — WHS = $whs ns (must be >= 0)"
    set timing_ok 0
}

proc parse_util_pct {rpt keyword} {
    foreach line [split $rpt "\n"] {
        if {[string match "*${keyword}*" $line]} {
            if {[regexp {\|\s*([\d.]+)\s*\|[^|]*\|[^|]*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|} $line -> used avail pct]} {
                return $pct
            }
        }
    }
    return "?"
}

set util_str  [report_utilization -return_string -quiet]
set pct_luts  [parse_util_pct $util_str "Slice LUTs"]
set pct_brams [parse_util_pct $util_str "Block RAM Tile"]

puts "INFO: Utilisation — LUTs ${pct_luts}%  BRAMs ${pct_brams}%"

foreach {res pct limit} [list "LUT" $pct_luts 80  "BRAM" $pct_brams 85] {
    if {$pct ne "?" && [expr {$pct > $limit}]} {
        puts "WARNING: $res utilisation ${pct}% exceeds ${limit}% — routing congestion risk"
    }
}

if {$timing_ok} {
    puts "INFO: ============================================"
    puts "INFO:  BUILD QUALITY GATES PASSED"
    puts "INFO:  WNS=+${wns}ns  WHS=+${whs}ns  LUTs=${pct_luts}%  BRAMs=${pct_brams}%"
    puts "INFO: ============================================"
    puts "INFO: Build complete."
} else {
    puts "ERROR: ============================================"
    puts "ERROR:  BUILD QUALITY GATES FAILED — timing not met"
    puts "ERROR:  WNS=${wns}ns  WHS=${whs}ns"
    puts "ERROR: ============================================"
    exit 1
}
