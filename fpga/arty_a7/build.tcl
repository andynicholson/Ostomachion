## Ostomachion — Vivado non-interactive build script
## Usage: vivado -mode batch -source fpga/arty_a7/build.tcl
##   Normal production build:
##     vivado -mode batch -source fpga/arty_a7/build.tcl
##   Debug build with ILA probes:
##     vivado -mode batch -source fpga/arty_a7/build.tcl -tclargs debug
##
## Produces:
##   build/arty_a7/ostomachion_arty_a7.bit        (production bitstream)
##   build/arty_a7/ostomachion_arty_a7.mcs        (Quad-SPI flash image)
##   build/arty_a7/ostomachion_arty_a7_debug.bit  (ILA debug, if -tclargs debug)
##   build/arty_a7/build_id.txt                   (version + git hash)
##   build/arty_a7/timing_summary.rpt             (setup/hold analysis)
##   build/arty_a7/utilization.rpt                (LUT/BRAM/IO counts)
##   build/arty_a7/drc.rpt                        (design rule violations)
##
## The script resolves paths relative to the project root, which is assumed
## to be two levels above this script's location:
##   fpga/arty_a7/build.tcl  →  project root = [file dirname [file dirname ...]]

## Set DEBUG_BUILD=1 if "debug" is passed as the first Tcl argument.
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
set build_dir   "$proj_root/build/arty_a7"
set neorv32_rtl "$proj_root/neorv32/rtl/core"
set fpga_dir    "$proj_root/fpga/arty_a7"

file mkdir $build_dir

puts "INFO: Project root : $proj_root"
puts "INFO: Build output : $build_dir"

# ---------------------------------------------------------------------------
# Create Vivado project
# ---------------------------------------------------------------------------
create_project ostomachion_arty_a7 "$build_dir/vivado_project" \
    -part xc7a100tcsg324-1 -force

set_property TARGET_LANGUAGE VHDL [current_project]

# ---------------------------------------------------------------------------
# Add NEORV32 core sources (library neorv32)
# Discovered by glob so the list stays correct when the submodule is updated.
# neorv32_application_image.vhd carries the default empty image; in the FPGA
# flow BOOT_MODE_SELECT=0 means the bootloader is used, so this is included.
# ---------------------------------------------------------------------------
set soc_files [lsort [glob "$neorv32_rtl/*.vhd"]]
puts "INFO: Found [llength $soc_files] NEORV32 core files in $neorv32_rtl"

add_files -fileset sources_1 $soc_files
foreach f $soc_files {
    set_property LIBRARY neorv32 [get_files $f]
}

# ---------------------------------------------------------------------------
# Add custom RTL: XBUS bridge (library work)
# Instantiated by arty_a7_top.vhd — not referenced inside the block design.
# The BD contains only Xilinx IP; NEORV32 and the bridge live in arty_a7_top.
# The FFT is provided by the Xilinx xfft IP instantiated in the BD; no
# custom FFT VHDL files are needed.
# ---------------------------------------------------------------------------
set accel_rtl "$proj_root/rtl"

add_files -fileset sources_1 [list \
    "$accel_rtl/xbus_axi4lite_bridge.vhd" \
]

# ---------------------------------------------------------------------------
# Add board-level top (library work) — thin IO primitives wrapper
# ---------------------------------------------------------------------------
add_files -fileset sources_1 "$fpga_dir/arty_a7_top.vhd"
set_property TOP arty_a7_top [get_filesets sources_1]

# ---------------------------------------------------------------------------
# Create the IP Integrator block design
# This sources ostomachion_bd.tcl which instantiates all IPs, connects
# clocks/resets, wires up the AXI fabric, and calls make_wrapper.
# The resulting ostomachion_bd_wrapper.vhd is added to sources_1 by the
# BD script; arty_a7_top remains the synthesis top.
# ---------------------------------------------------------------------------
puts "INFO: Creating IP Integrator block design..."
source "$fpga_dir/ostomachion_bd.tcl"

# ---------------------------------------------------------------------------
# Add XDC constraints
# ---------------------------------------------------------------------------
add_files -fileset constrs_1 "$fpga_dir/arty_a7.xdc"

# ---------------------------------------------------------------------------
# Set VHDL-2008 only for NEORV32 core files and our custom RTL.
# DO NOT apply to Xilinx IP-generated files — they use VHDL-93/2000 and
# setting VHDL-2008 on them breaks synthesis (FILE_TYPE mismatch).
# ---------------------------------------------------------------------------
set rtl_vhdl2008_files [concat $soc_files [list \
    "$accel_rtl/xbus_axi4lite_bridge.vhd" \
    "$fpga_dir/arty_a7_top.vhd"           \
]]
foreach f $rtl_vhdl2008_files {
    set_property FILE_TYPE {VHDL 2008} [get_files $f]
}

# ---------------------------------------------------------------------------
# Synthesis
# launch_runs synth_1 handles the OOC dependency chain automatically:
#   – synthesises each BD sub-IP as an OOC checkpoint
#   – then synthesises the BD wrapper and the top-level design
# Verbose mode is enabled on the synthesis run step so detailed messages
# appear in the run log ($build_dir/vivado_project/.../synth_1/runme.log).
# ---------------------------------------------------------------------------
## Synthesis verbose output goes to synth_1/runme.log in the project run dir.
## The direct implementation commands below use -verbose for console output.

puts "INFO: ── Synthesis (launch_runs) ───────────────────────────────────────"
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: Synthesis failed — see:"
    puts "  $build_dir/vivado_project/ostomachion_arty_a7.runs/synth_1/runme.log"
    exit 1
}
puts "INFO: Synthesis complete."

# Open the synthesised checkpoint so implementation commands work in-memory.
open_run synth_1 -name synth_1

# ---------------------------------------------------------------------------
# Implementation — direct commands with -verbose for real-time diagnostics
# ---------------------------------------------------------------------------
puts "INFO: ── Optimisation ───────────────────────────────────────────────────"
opt_design -verbose

puts "INFO: ── Placement ──────────────────────────────────────────────────────"
place_design -verbose

puts "INFO: ── Physical optimisation (post-place) ─────────────────────────────"
phys_opt_design -verbose

puts "INFO: ── Routing ────────────────────────────────────────────────────────"
route_design -verbose

puts "INFO: ── Save implementation checkpoint ────────────────────────────────"
write_checkpoint -force "$build_dir/impl_final.dcp"
puts "INFO: Checkpoint saved to $build_dir/impl_final.dcp"

# ---------------------------------------------------------------------------
# Optional ILA debug build
# When DEBUG_BUILD=1 (pass -tclargs debug), insert ILA cores on key nets
# and produce a separate debug bitstream.  The production bitstream is
# written first so a failing debug insertion does not block deployment.
# ---------------------------------------------------------------------------
if {$DEBUG_BUILD} {
    puts "INFO: ── ILA insertion (debug build) ────────────────────────────────"

    ## Mark key nets for ILA capture.
    ## AXI-Stream between AXI DMA MM2S output and xfft input
    set mm2s_nets [get_nets -hierarchical -filter {NAME =~ *M_AXIS_MM2S*} -quiet]
    ## AXI-Stream between xfft output and AXI DMA S2MM input
    set s2mm_nets [get_nets -hierarchical -filter {NAME =~ *S_AXIS_S2MM*} -quiet]
    ## DMA status register outputs (interrupt lines)
    set irq_nets  [get_nets -hierarchical -filter {NAME =~ *introut*} -quiet]
    ## xfft overflow status
    set ovflo_nets [get_nets -hierarchical -filter {NAME =~ *m_axis_status*} -quiet]

    foreach net [concat $mm2s_nets $s2mm_nets $irq_nets $ovflo_nets] {
        set_property MARK_DEBUG true [get_nets $net]
    }

    ## Implement the ILA cores using the Vivado debug flow
    implement_debug_core
    write_debug_probes -force "$build_dir/debug_probes.ltx"
    puts "INFO: Debug probes written to $build_dir/debug_probes.ltx"
    puts "INFO: Load this .ltx file in Vivado Hardware Manager alongside the debug bitstream."

    write_bitstream \
        -force \
        "$build_dir/ostomachion_arty_a7_debug.bit"
    puts "INFO: Debug bitstream → $build_dir/ostomachion_arty_a7_debug.bit"
    puts "INFO: Use with debug_probes.ltx in Vivado Hardware Manager."
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

# Gate on DRC errors: any ERROR-level violation must block bitstream deployment.
set drc_str [report_drc -return_string -quiet]
if {[regexp {ERROR} $drc_str]} {
    puts "ERROR: DRC violations detected — see $build_dir/drc.rpt"
    puts "ERROR: Resolve all DRC errors before deploying bitstream."
    exit 1
}
puts "INFO: DRC clean — no errors found."

# ---------------------------------------------------------------------------
# Build ID — capture git semver tag + hash + timestamp, embed in bitstream
# USER_CODE, and write to build_id.txt for firmware/field version matching.
# ---------------------------------------------------------------------------
set git_hash    "unknown"
set git_version "unknown"
catch {
    set git_hash    [string trim [exec git -C $proj_root describe --always --dirty --abbrev=8]]
    # Try for an annotated/lightweight tag first (e.g. v1.0.0 or v1.0.0-3-gabc1234)
    set git_version [string trim [exec git -C $proj_root describe --tags --always --dirty --abbrev=8]]
}
set build_ts  [clock format [clock seconds] -format {%Y%m%d_%H%M%S}]
set build_id  "${git_version} (git: ${git_hash}, built: ${build_ts})"

# USERID must be an 8-character hex string (32-bit).  Pad / truncate the hash.
set id_clean [string map {- "" g ""} $git_hash]
set id_clean [string range "${id_clean}00000000" 0 7]
set_property BITSTREAM.CONFIG.USERID "0x${id_clean}" [current_design]

set fid [open "$build_dir/build_id.txt" w]
puts $fid $build_id
close $fid
puts "INFO: Build ID : $build_id"
puts "INFO: USERID   : 0x${id_clean}  (readable via JTAG config status register)"

# ---------------------------------------------------------------------------
# SPI configuration mode — required for write_cfgmem (Quad-SPI flash)
# The Arty A7-100T has a Micron N25Q128A (MT25QL128) on-board Quad-SPI flash.
# Setting these properties before write_bitstream embeds them in the bitstream
# so that the FPGA auto-configures from flash on every power cycle once
# 'make fpga-flash' has been run.
# ---------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4        [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE Yes     [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33         [current_design]
set_property CONFIG_MODE SPIx4                      [current_design]

# ---------------------------------------------------------------------------
# Bitstream
# ---------------------------------------------------------------------------
puts "INFO: ── Bitstream ──────────────────────────────────────────────────────"
write_bitstream \
    -force \
    -verbose \
    "$build_dir/ostomachion_arty_a7.bit"

puts "INFO: Production bitstream → $build_dir/ostomachion_arty_a7.bit"

# ---------------------------------------------------------------------------
# Quad-SPI flash image (MCS) — for 'make fpga-flash' persistent programming
# Generates a Vivado-compatible MCS configuration memory file for the
# Micron MT25QL128 / N25Q128A on-board Quad-SPI flash (16 MB, SPIx4).
# Use with program_flash.tcl / 'make fpga-flash' to survive power cycles.
# ---------------------------------------------------------------------------
puts "INFO: ── Flash image (MCS) ───────────────────────────────────────────────"
write_cfgmem \
    -format mcs \
    -interface SPIx4 \
    -size 16 \
    -loadbit "up 0x00000000 $build_dir/ostomachion_arty_a7.bit" \
    -force \
    "$build_dir/ostomachion_arty_a7.mcs"
puts "INFO: Flash image → $build_dir/ostomachion_arty_a7.mcs"
puts "INFO: Run 'make fpga-flash' to program the on-board Quad-SPI flash."

# ---------------------------------------------------------------------------
# Post-build quality gates (timing closure check)
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

# --- Resource headroom -------------------------------------------------------
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

# --- Summary -----------------------------------------------------------------
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
