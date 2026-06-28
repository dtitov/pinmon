// Package pinmon implements a GPU monitor dashboard for vertical displays.

package main

import "errors"
import "os"
import "fmt"
import "slices"
import "strings"
import "encoding/binary"
import "flag"
import "time"

import "github.com/NVIDIA/go-nvml/pkg/nvml"
import "github.com/khirono/go-i2c/smbus"

// nvidiaCompatibleDevice lists the PCI device IDs of supported NVIDIA GPUs.
var nvidiaCompatibleDevice = []uint32{0x2b8510de}

// compatibleSubDevices lists the PCI subsystem IDs of supported EVGA boards.
var compatibleSubDevices = []uint32{0x89e31043}

// DashWidth is the inner width of every dashboard panel in characters.
const dashWidth = 34

// BarWidth is the width of the gauge bars in characters.
const barWidth = 18

// ContentWidth is the usable width after the leading space.
const contentWidth = dashWidth - 1

// ANSI styling escape codes for the dashboard UI.
const (
	ansiReset = "\033[0m"
	ansiDim   = "\033[2m"
	ansiBold  = "\033[1m"

	ansiGreen   = "\033[38;5;77m"
	ansiYellow  = "\033[38;5;221m"
	ansiOrange  = "\033[38;5;215m"
	ansiRed     = "\033[38;5;203m"
	ansiCyan    = "\033[38;5;81m"
	ansiBlue    = "\033[38;5;75m"
	ansiMagenta = "\033[38;5;177m"
	ansiGrey    = "\033[38;5;245m"
)

// SupportedDevice represents a GPU monitor target.
type SupportedDevice struct {
	sensorNumber           int
	deviceHandle           nvml.Device
	deviceDetailIdentifier string
}

// Identifier returns the unique device identifier string.
func (self SupportedDevice) Identifier() string {
	return self.deviceDetailIdentifier
}

// SupportedDevicePin represents a voltage/current sensor pin on the GPU.
type SupportedDevicePin struct {
	voltage float64
	current float64
}

// Current returns the current in amperes.
func (self SupportedDevicePin) Current() float64 {
	return self.current
}

// FindSupportedDevices enumerates compatible GPU devices via NVML and I2C sensor buses.
func FindSupportedDevices() ([]SupportedDevice, error) {
	var found []SupportedDevice

	count, ret := nvml.DeviceGetCount()
	if !errors.Is(ret, nvml.SUCCESS) {
		return nil, fmt.Errorf("nvmlDeviceGetCount failed")
	}

	for index := range count {
		device, ret := nvml.DeviceGetHandleByIndex(index)
		if !errors.Is(ret, nvml.SUCCESS) {
			return nil, fmt.Errorf("nvmlDeviceGetHandleByIndex failed")
		}

		info, ret := nvml.DeviceGetPciInfo(device)
		if !errors.Is(ret, nvml.SUCCESS) {
			return nil, fmt.Errorf("nvmlDeviceGetPciInfo failed")
		}

		if !slices.Contains(nvidiaCompatibleDevice, info.PciDeviceId) {
			continue
		}
		if !slices.Contains(compatibleSubDevices, info.PciSubSystemId) {
			continue
		}

		uuid, ret := nvml.DeviceGetUUID(device)
		if !errors.Is(ret, nvml.SUCCESS) {
			return nil, fmt.Errorf("nvmlDeviceGetUUID failed")
		}

		number, err := findSupportedDeviceSensorNumber(info)
		if err != nil {
			return nil, err
		}

		current := SupportedDevice{
			sensorNumber:           number,
			deviceHandle:           device,
			deviceDetailIdentifier: uuid,
		}

		found = append(found, current)
	}

	return found, nil
}

// ReadSupportedDevicePins reads voltage and current from the GPU's I2C sensor block.
func ReadSupportedDevicePins(target SupportedDevice) ([]SupportedDevicePin, error) {
	// Read sensor data using the SMBus protocol derived from:
	// - https://long-cat.net/gitea/moosecrap/evga-icx
	// - https://github.com/LibreHardwareMonitor/LibreHardwareMonitor
	// Sensor interaction based on:
	// - https://github.com/Timic3/astral-power-monitoring
	// Inspired by:
	// - https://github.com/jan-provaznik/sus

	bus, err := smbus.Open(target.sensorNumber)
	if err != nil {
		return nil, err
	}
	defer bus.Close()

	err = bus.SetSlaveAddr(0x2B, false)
	if err != nil {
		return nil, err
	}

	buffer := make([]byte, 24)
	length, err := bus.ReadI2CBlockData(0x80, buffer)
	if err != nil {
		return nil, err
	}

	if length != 24 {
		return nil, fmt.Errorf("could not read sensor device")
	}

	result := make([]SupportedDevicePin, 6)
	for index := range 6 {
		start := 4 * index
		result[index] = readBuffer(buffer[start : start+4])
	}

	return result, nil
}

// ReadSupportedDeviceTemperature returns the GPU core temperature in degrees Celsius.
func ReadSupportedDeviceTemperature(target SupportedDevice) (uint32, error) {
	value, ret := nvml.DeviceGetTemperature(target.deviceHandle, nvml.TEMPERATURE_GPU)
	if !errors.Is(ret, nvml.SUCCESS) {
		return 0, fmt.Errorf("nvmlDeviceGetTemperature failed")
	}
	return value, nil
}

// ReadSupportedDeviceMemory returns the used and total VRAM memory in bytes.
func ReadSupportedDeviceMemory(target SupportedDevice) (uint64, uint64, error) {
	info, ret := nvml.DeviceGetMemoryInfo(target.deviceHandle)
	if !errors.Is(ret, nvml.SUCCESS) {
		return 0, 0, fmt.Errorf("nvmlDeviceGetMemoryInfo failed")
	}
	return info.Used, info.Total, nil
}

// ReadSupportedDeviceUtilization returns the GPU compute utilization in percent.
func ReadSupportedDeviceUtilization(target SupportedDevice) (uint32, error) {
	rates, ret := nvml.DeviceGetUtilizationRates(target.deviceHandle)
	if !errors.Is(ret, nvml.SUCCESS) {
		return 0, fmt.Errorf("nvmlDeviceGetUtilizationRates failed")
	}
	return rates.Gpu, nil
}

// ReadSupportedDeviceFanSpeeds returns the fan speed percentages for all fan groups.
func ReadSupportedDeviceFanSpeeds(target SupportedDevice) ([]uint32, error) {
	count, ret := nvml.DeviceGetNumFans(target.deviceHandle)
	if !errors.Is(ret, nvml.SUCCESS) {
		return nil, fmt.Errorf("nvmlDeviceGetNumFans failed")
	}

	speeds := make([]uint32, 0, count)
	for fan := range count {
		value, ret := nvml.DeviceGetFanSpeed_v2(target.deviceHandle, fan)
		if !errors.Is(ret, nvml.SUCCESS) {
			return nil, fmt.Errorf("nvmlDeviceGetFanSpeed_v2 failed")
		}
		speeds = append(speeds, value)
	}

	return speeds, nil
}

// ReadSupportedDeviceLoad returns the current power draw in watts.
func ReadSupportedDeviceLoad(target SupportedDevice) (float64, error) {
	value, ret := nvml.DeviceGetPowerUsage(target.deviceHandle)
	if !errors.Is(ret, nvml.SUCCESS) {
		return -1, fmt.Errorf("nvmlDeviceGetPowerUsage failed")
	}
	return float64(value) / 1000, nil
}

// readBuffer decodes four bytes from an I2C sensor into a SupportedDevicePin.
func readBuffer(buffer []byte) SupportedDevicePin {
	wordOne := binary.BigEndian.Uint16(buffer[0:2])
	wordTwo := binary.BigEndian.Uint16(buffer[2:4])

	return SupportedDevicePin{
		voltage: float64(wordOne) / 1000,
		current: float64(wordTwo) / 1000,
	}
}

// findSupportedDeviceSensorNumber locates the lowest-numbered I2C bus connected to the GPU.
func findSupportedDeviceSensorNumber(info nvml.PciInfo) (int, error) {
	root := fmt.Sprintf("/sys/bus/pci/devices/%04x:%02x:%02x.0",
		info.Domain, info.Bus, info.Device)

	final := 0xffff
	value := 0xffff

	entries, err := os.ReadDir(root)
	if err != nil {
		return 0xffff, err
	}

	for _, item := range entries {
		if !strings.HasPrefix(item.Name(), "i2c-") {
			continue
		}

		num, err := fmt.Sscanf(item.Name(), "i2c-%d", &value)
		if err != nil {
			return 0xffff, err
		}
		if num != 1 {
			continue
		}
		if value < final {
			final = value
		}
	}

	if final == 0xffff {
		return final, fmt.Errorf("could not find sensor device")
	}

	return final, nil
}

func main() {
	defer nvml.Shutdown()

	interval := flag.Duration("t", time.Second, "Monitoring interval")
	flag.Parse()

	ret := nvml.Init()
	if !errors.Is(ret, nvml.SUCCESS) {
		fmt.Println("nvmlInit failed")
		os.Exit(1)
	}

	list, err := FindSupportedDevices()
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	if len(list) < 1 {
		fmt.Println("Could not find any compatible devices. Exiting.")
		os.Exit(0)
	}

	// Hide the cursor and ensure it is restored on exit.
	fmt.Print("\033[?25l")
	defer fmt.Print("\033[?25h")

	for {
		// Move cursor to top-left and clear screen so readings stay fixed in place.
		fmt.Print("\033[H\033[2J")

		printDashboardHeader()

		for index, device := range list {
			err := deviceReport(index, device)
			if err != nil {
				fmt.Print("\033[?25h")
				fmt.Println(err)
				os.Exit(1)
			}
		}
		time.Sleep(*interval)
	}
}

// printDashboardHeader renders the title strip shown above the dashboard panels.
func printDashboardHeader() {
	stamp := time.Now().Format("15:04:05")
	title := "\n\n\n\n\n\nPINMON · GPU MONITOR\n"

	fmt.Println()
	fmt.Printf("  %s%s%s%s\n", ansiBold, ansiCyan, title, ansiReset)
	fmt.Printf("  %s%s%s\n", ansiDim, stamp, ansiReset)
}

// deviceReport gathers metrics for a single GPU and renders its dashboard panel.
func deviceReport(index int, device SupportedDevice) error {
	// Gather metrics from NVML.
	load, err := ReadSupportedDeviceLoad(device)
	if err != nil {
		return err
	}

	temp, err := ReadSupportedDeviceTemperature(device)
	if err != nil {
		return err
	}

	memUsed, memTotal, err := ReadSupportedDeviceMemory(device)
	if err != nil {
		return err
	}

	util, err := ReadSupportedDeviceUtilization(device)
	if err != nil {
		return err
	}

	fans, err := ReadSupportedDeviceFanSpeeds(device)
	if err != nil {
		return err
	}

	// Gather metrics from the I2C sensor interface.
	pins, err := ReadSupportedDevicePins(device)
	if err != nil {
		return err
	}

	// Calculate pin statistics.
	totalCurrent := 0.0
	upperCurrent := 0.0
	lowerCurrent := 1e6

	for _, pin := range pins {
		value := pin.Current()
		if value > upperCurrent {
			upperCurrent = value
		}
		if value < lowerCurrent {
			lowerCurrent = value
		}
		totalCurrent = totalCurrent + value
	}

	// Calculate pin current balance (1.0 = perfectly even).
	matchCurrent := 0.0
	if upperCurrent > 0 {
		matchCurrent = lowerCurrent / upperCurrent
	}

	memPct := 100 * float64(memUsed) / float64(memTotal)
	memUsed_ := float64(memUsed) / 1073741824
	memTotal_ := float64(memTotal) / 1073741824

	// Render the GPU panel.
	fmt.Println()
	panelTop(fmt.Sprintf("GPU %d", index))

	panelSep()
	gaugeLine("util", float64(util), 100,
		fmt.Sprintf("%3d %%", util), pctColor(float64(util)))
	gaugeLine("temp", float64(temp), 100,
		fmt.Sprintf("%3d C", temp), tempColor(float64(temp)))
	gaugeLine("vram", memPct, 100,
		fmt.Sprintf("%.0f/%.0f G", memUsed_, memTotal_), pctColor(memPct))
	gaugeLine("powr", load, 600,
		fmt.Sprintf("%.0f W", load), ansiMagenta)
	for fanIndex, fan := range fans {
		gaugeLine(fmt.Sprintf("fan%d", fanIndex), float64(fan), 100,
			fmt.Sprintf("%3d %%", fan), pctColor(float64(fan)))
	}

	panelSep()
	textLine(fmt.Sprintf("%stotal%s %s%.2f A%s   %sbalance%s %s%.0f%%%s",
		ansiGrey, ansiReset, ansiBold, totalCurrent, ansiReset,
		ansiGrey, ansiReset, balanceColor(matchCurrent),
		100*matchCurrent, ansiReset))

	// Render per-pin current bars (fixed 9 A full-scale).
	for pinIndex, pin := range pins {
		gaugeLine(fmt.Sprintf("pin%d", pinIndex), pin.Current(), 9,
			fmt.Sprintf("%5.2f A", pin.Current()), ansiBlue)
	}
	panelBottom()

	return nil
}

// panelTop renders the top border of a dashboard panel with its title.
func panelTop(title string) {
	label := " " + title + " "
	fill := max(dashWidth-len([]rune(label)), 0)
	fmt.Printf(" %s╭%s%s%s%s%s%s╮%s\n",
		ansiGrey, ansiReset, ansiBold, ansiCyan, label, ansiReset,
		ansiGrey+strings.Repeat("─", fill), ansiReset)
}

// panelBottom renders the bottom border of a dashboard panel.
func panelBottom() {
	fmt.Printf(" %s╰%s╯%s\n",
		ansiGrey, strings.Repeat("─", dashWidth), ansiReset)
}

// panelSep renders a horizontal separator line inside a panel.
func panelSep() {
	fmt.Printf(" %s├%s┤%s\n",
		ansiGrey, strings.Repeat("─", dashWidth), ansiReset)
}

// panelLine prints a content line with fixed-width borders and padding. visibleLen is the
// on-screen width of the content excluding ANSI escapes, used to calculate padding.
func panelLine(content string, visibleLen int) {
	pad := max(contentWidth-visibleLen, 0)
	fmt.Printf(" %s│%s %s%s%s│%s\n",
		ansiGrey, ansiReset, content, strings.Repeat(" ", pad),
		ansiGrey, ansiReset)
}

// textLine wraps panelLine but computes padding using unstyled character width.
func textLine(content string) {
	panelLine(content, visibleWidth(content))
}

// gaugeLine renders a labeled horizontal bar with a trailing readout value.
func gaugeLine(label string, value float64, scale float64, readout string, color string) {
	bar := makeBar(value, scale, color)
	content := fmt.Sprintf("%s%-4s%s %s %s%9s%s",
		ansiGrey, label, ansiReset, bar, color, readout, ansiReset)
	visible := 4 + 1 + barWidth + 1 + 9
	// The readout field is right-aligned to 9 columns so every gauge line aligns flush.
	panelLine(content, visible)
}

// makeBar builds a fixed-width gauge using block characters.
func makeBar(value float64, scale float64, color string) string {
	if scale <= 0 {
		scale = 1
	}
	ratio := value / scale
	if ratio < 0 {
		ratio = 0
	}
	if ratio > 1 {
		ratio = 1
	}
	filled := int(ratio*float64(barWidth) + 0.5)
	empty := barWidth - filled
	return fmt.Sprintf("%s%s%s%s%s",
		color, strings.Repeat("█", filled),
		ansiDim, strings.Repeat("░", empty), ansiReset)
}

// visibleWidth counts on-screen characters, ignoring ANSI escape sequences.
func visibleWidth(s string) int {
	width := 0
	inEscape := false
	for _, r := range s {
		if inEscape {
			if r == 'm' {
				inEscape = false
			}
			continue
		}
		if r == '\033' {
			inEscape = true
			continue
		}
		width++
	}
	return width
}

// pctColor returns the ANSI color code for percentage-based metrics.
func pctColor(value float64) string {
	switch {
	case value >= 90:
		return ansiRed
	case value >= 70:
		return ansiOrange
	case value >= 40:
		return ansiYellow
	default:
		return ansiGreen
	}
}

// tempColor returns the ANSI color code for temperature metrics.
func tempColor(value float64) string {
	switch {
	case value >= 85:
		return ansiRed
	case value >= 70:
		return ansiOrange
	case value >= 55:
		return ansiYellow
	default:
		return ansiGreen
	}
}

// balanceColor returns the ANSI color code for pin current balance metrics.
func balanceColor(ratio float64) string {
	switch {
	case ratio >= 0.85:
		return ansiGreen
	case ratio >= 0.6:
		return ansiYellow
	default:
		return ansiOrange
	}
}
