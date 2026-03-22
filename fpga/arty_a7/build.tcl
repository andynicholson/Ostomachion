## Ostomachion — Vivado non-interactive build script
## Usage: vivado -mode batch -source fpga/arty_a7/build.tcl
##
## Produces: build/arty_a7/ostomachion_arty_a7.bit
##
## The script resolves paths relative to the project root, which is assumed
## to be two levels above this script's location:
##   fpga/arty_a7/build.tcl  →  project root = [file dirname [file dirname ...]]

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
# The file_list_soc.f lists all required files in dependency order.
# ---------------------------------------------------------------------------
set soc_files [list \
    "$neorv32_rtl/neorv32_package.vhd"          \
    "$neorv32_rtl/neorv32_sys.vhd"              \
    "$neorv32_rtl/neorv32_fifo.vhd"             \
    "$neorv32_rtl/neorv32_cpu_decompressor.vhd" \
    "$neorv32_rtl/neorv32_cpu_frontend.vhd"     \
    "$neorv32_rtl/neorv32_cpu_control.vhd"      \
    "$neorv32_rtl/neorv32_cpu_counters.vhd"     \
    "$neorv32_rtl/neorv32_cpu_regfile.vhd"      \
    "$neorv32_rtl/neorv32_cpu_cp_shifter.vhd"   \
    "$neorv32_rtl/neorv32_cpu_cp_muldiv.vhd"    \
    "$neorv32_rtl/neorv32_cpu_cp_bitmanip.vhd"  \
    "$neorv32_rtl/neorv32_cpu_cp_fpu.vhd"       \
    "$neorv32_rtl/neorv32_cpu_cp_cfu.vhd"       \
    "$neorv32_rtl/neorv32_cpu_cp_cond.vhd"      \
    "$neorv32_rtl/neorv32_cpu_cp_crypto.vhd"    \
    "$neorv32_rtl/neorv32_cpu_alu.vhd"          \
    "$neorv32_rtl/neorv32_cpu_lsu.vhd"          \
    "$neorv32_rtl/neorv32_cpu_pmp.vhd"          \
    "$neorv32_rtl/neorv32_cpu.vhd"              \
    "$neorv32_rtl/neorv32_cache.vhd"            \
    "$neorv32_rtl/neorv32_bus.vhd"              \
    "$neorv32_rtl/neorv32_dma.vhd"              \
    "$neorv32_rtl/neorv32_application_image.vhd"\
    "$neorv32_rtl/neorv32_imem.vhd"             \
    "$neorv32_rtl/neorv32_dmem.vhd"             \
    "$neorv32_rtl/neorv32_xbus.vhd"             \
    "$neorv32_rtl/neorv32_bootloader_image.vhd" \
    "$neorv32_rtl/neorv32_boot_rom.vhd"         \
    "$neorv32_rtl/neorv32_cfs.vhd"              \
    "$neorv32_rtl/neorv32_sdi.vhd"              \
    "$neorv32_rtl/neorv32_gpio.vhd"             \
    "$neorv32_rtl/neorv32_wdt.vhd"              \
    "$neorv32_rtl/neorv32_clint.vhd"            \
    "$neorv32_rtl/neorv32_uart.vhd"             \
    "$neorv32_rtl/neorv32_spi.vhd"              \
    "$neorv32_rtl/neorv32_twi.vhd"              \
    "$neorv32_rtl/neorv32_twd.vhd"              \
    "$neorv32_rtl/neorv32_pwm.vhd"              \
    "$neorv32_rtl/neorv32_trng.vhd"             \
    "$neorv32_rtl/neorv32_neoled.vhd"           \
    "$neorv32_rtl/neorv32_gptmr.vhd"            \
    "$neorv32_rtl/neorv32_onewire.vhd"          \
    "$neorv32_rtl/neorv32_slink.vhd"            \
    "$neorv32_rtl/neorv32_sysinfo.vhd"          \
    "$neorv32_rtl/neorv32_debug_dtm.vhd"        \
    "$neorv32_rtl/neorv32_debug_auth.vhd"       \
    "$neorv32_rtl/neorv32_debug_dm.vhd"         \
    "$neorv32_rtl/neorv32_top.vhd"              \
]

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

# ---------------------------------------------------------------------------
# Bitstream
# ---------------------------------------------------------------------------
puts "INFO: ── Bitstream ──────────────────────────────────────────────────────"
write_bitstream \
    -force \
    -verbose \
    "$build_dir/ostomachion_arty_a7.bit"

puts "INFO: Bitstream written to $build_dir/ostomachion_arty_a7.bit"

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
