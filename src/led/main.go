// jarvis-led — радужная подсветка кольца Яндекс Станции Лайт.
//
// Кольцо управляется драйвером aw9110 через sysfs:
//   /sys/class/leds/micro:{red,green,blue}:ring{1,2,3}/brightness  (0..255)
//
// Программа крутит оттенок по кругу, каждый сегмент со сдвигом 120°,
// поэтому цвет «переливается» по кольцу. Если подсветку перехватил
// maind (Алиса слушает или говорит), программа замечает чужие значения
// и на несколько секунд отступает, чтобы не было мерцания.
//
// Сборка под колонку:
//   GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o jarvis-led .
// Для aarch64: GOARCH=arm64, GOARM не задаётся.
package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"time"
)

const ledRoot = "/sys/class/leds"

var channels = [3]string{"red", "green", "blue"}

type rgb [3]int

func ledPath(ring int, channel string) string {
	return filepath.Join(ledRoot, fmt.Sprintf("micro:%s:ring%d", channel, ring), "brightness")
}

func writeLED(ring, channel, value int) error {
	return os.WriteFile(ledPath(ring, channels[channel]), []byte(fmt.Sprintf("%d\n", value)), 0o644)
}

func readLED(ring, channel int) int {
	raw, err := os.ReadFile(ledPath(ring, channels[channel]))
	if err != nil {
		return -1
	}
	value := 0
	for _, c := range raw {
		if c < '0' || c > '9' {
			break
		}
		value = value*10 + int(c-'0')
	}
	return value
}

func readState() ([3]rgb, error) {
	var state [3]rgb
	for ring := 1; ring <= 3; ring++ {
		for ch := 0; ch < 3; ch++ {
			value := readLED(ring, ch)
			if value < 0 {
				return state, fmt.Errorf("нет доступа к %s", ledPath(ring, channels[ch]))
			}
			state[ring-1][ch] = value
		}
	}
	return state, nil
}

func writeState(state [3]rgb) {
	for ring := 1; ring <= 3; ring++ {
		for ch := 0; ch < 3; ch++ {
			_ = writeLED(ring, ch, state[ring-1][ch])
		}
	}
}

// hsv2rgb: hue 0..360, saturation/value 0..1.
func hsv2rgb(hue, saturation, value float64) (float64, float64, float64) {
	c := value * saturation
	x := c * (1 - math.Abs(math.Mod(hue/60, 2)-1))
	m := value - c
	var r, g, b float64
	switch {
	case hue < 60:
		r, g, b = c, x, 0
	case hue < 120:
		r, g, b = x, c, 0
	case hue < 180:
		r, g, b = 0, c, x
	case hue < 240:
		r, g, b = 0, x, c
	case hue < 300:
		r, g, b = x, 0, c
	default:
		r, g, b = c, 0, x
	}
	return r + m, g + m, b + m
}

func clamp(value, low, high float64) float64 {
	return math.Max(low, math.Min(high, value))
}

func main() {
	fps := flag.Int("fps", 25, "кадров в секунду")
	bright := flag.Float64("bright", 0.75, "яркость 0..1")
	speed := flag.Float64("speed", 45, "скорость вращения оттенка, градусов в секунду")
	mode := flag.String("mode", "rainbow", "rainbow | breathe | off")
	pause := flag.Duration("pause", 4*time.Second, "сколько отступать, если подсветку взяла Алиса")
	once := flag.Bool("once", false, "записать один кадр и выйти")
	flag.Parse()

	if *mode == "off" {
		writeState([3]rgb{})
		fmt.Println("подсветка выключена")
		return
	}

	if _, err := readState(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	start := time.Now()
	last := [3]rgb{{-1, -1, -1}, {-1, -1, -1}, {-1, -1, -1}}
	var pausedUntil time.Time
	frame := 0

	for {
		elapsed := time.Since(start).Seconds()

		var want [3]rgb
		for ring := 0; ring < 3; ring++ {
			var hue, value float64
			if *mode == "breathe" {
				hue = math.Mod(elapsed*(*speed), 360)
				value = *bright * (0.45 + 0.55*(0.5+0.5*math.Sin(elapsed*1.2)))
			} else {
				hue = math.Mod(elapsed*(*speed)+float64(ring)*120, 360)
				// лёгкая волна яркости, чтобы кольцо «дышало», а не мигало
				value = *bright * (0.78 + 0.22*math.Sin(elapsed*2.0+float64(ring)*2*math.Pi/3))
			}
			value = clamp(value, 0, 1)
			r, g, b := hsv2rgb(hue, 1, value)
			want[ring] = rgb{int(math.Round(r * 255)), int(math.Round(g * 255)), int(math.Round(b * 255))}
		}

		if time.Now().Before(pausedUntil) {
			time.Sleep(time.Second / time.Duration(*fps))
			continue
		}

		// Если кто-то (maind) поменял цвет — отступаем, чтобы не мерцать.
		if last[0][0] >= 0 {
			if current, err := readState(); err == nil && current != last {
				pausedUntil = time.Now().Add(*pause)
				last = [3]rgb{{-1, -1, -1}, {-1, -1, -1}, {-1, -1, -1}}
				continue
			}
		}

		if want != last {
			writeState(want)
			last = want
		}

		frame++
		if *once && frame > 0 {
			return
		}
		time.Sleep(time.Second / time.Duration(*fps))
	}
}
