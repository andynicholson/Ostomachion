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
    -part xc7a35tcsg324-1 -force

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
# Add board-level top (library work)
# ---------------------------------------------------------------------------
add_files -fileset sources_1 "$fpga_dir/arty_a7_top.vhd"
set_property TOP arty_a7_top [get_filesets sources_1]

# ---------------------------------------------------------------------------
# Add XDC constraints
# ---------------------------------------------------------------------------
add_files -fileset constrs_1 "$fpga_dir/arty_a7.xdc"

# ---------------------------------------------------------------------------
# Set VHDL language standard to 2008 for all sources
# ---------------------------------------------------------------------------
set_property FILE_TYPE {VHDL 2008} [get_files *.vhd]

# ---------------------------------------------------------------------------
# Synthesis
# ---------------------------------------------------------------------------
puts "INFO: Starting synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}
puts "INFO: Synthesis complete."

# ---------------------------------------------------------------------------
# Implementation
# ---------------------------------------------------------------------------
puts "INFO: Starting implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}
puts "INFO: Implementation complete."

# ---------------------------------------------------------------------------
# Bitstream generation
# ---------------------------------------------------------------------------
puts "INFO: Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: Bitstream generation failed!"
    exit 1
}

# Copy bitstream to a well-known location at the project root
set bit_src "$build_dir/vivado_project/ostomachion_arty_a7.runs/impl_1/arty_a7_top.bit"
set bit_dst "$build_dir/ostomachion_arty_a7.bit"
file copy -force $bit_src $bit_dst

puts "INFO: Bitstream written to $bit_dst"

# ---------------------------------------------------------------------------
# Post-build quality gates
#
# These run inside the completed implementation to verify the build meets
# production quality requirements.  Any failure exits non-zero so that
# make fpga-synth returns an error to the calling shell / CI system.
# ---------------------------------------------------------------------------
puts "INFO: Running post-build quality checks..."

open_run impl_1

# --- 1. Timing closure -------------------------------------------------------
# get_timing_paths works on an open_run (STATS.* properties do not).
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

# --- 2. Resource headroom ----------------------------------------------------
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

set util_rpt  [report_utilization -return_string -quiet]
set pct_luts  [parse_util_pct $util_rpt "Slice LUTs"]
set pct_brams [parse_util_pct $util_rpt "Block RAM Tile"]

puts "INFO: Utilisation — LUTs ${pct_luts}%  BRAMs ${pct_brams}%"

foreach {res pct limit} [list "LUT" $pct_luts 80  "BRAM" $pct_brams 85] {
    if {$pct ne "?" && $pct > $limit} {
        puts "WARNING: $res utilisation ${pct}% exceeds ${limit}% threshold — routing congestion risk"
    }
}

# --- 3. Summary --------------------------------------------------------------
set pass 1
if {!$timing_ok} { set pass 0 }

if {$pass} {
    puts "INFO: ============================================"
    puts "INFO:  BUILD QUALITY GATES PASSED"
    puts "INFO:  WNS=+${wns}ns  WHS=+${whs}ns  LUTs=${pct_luts}%  BRAMs=${pct_brams}%"
    puts "INFO: ============================================"
    puts "INFO: Build complete."
} else {
    puts "ERROR: ============================================"
    puts "ERROR:  BUILD QUALITY GATES FAILED"
    if {!$timing_ok} { puts "ERROR:  - Timing not met: WNS=$wns ns  WHS=$whs ns" }
    puts "ERROR: ============================================"
    exit 1
}
