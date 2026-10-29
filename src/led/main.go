// jarvis-led — голубая подсветка кольца, пока Джарвис отвечает.
//
// Радужной анимации больше нет. В покое кольцо выключено и полностью
// принадлежит Алисе (громкость, «слушаю», свои ответы). Как только мост
// отдаёт ответ языковой модели, загорается ровное голубое «дыхание» на время
// озвучки — и гаснет.
//
// Откуда берётся событие: мост пишет журнал
//
//	/data/opt/quasar-bridge/conversations.jsonl
//
// строками вида
//
//	{"event":"response","route":"llm","text":"Сэр, ..."}
//
// Демон читает только новые строки (хвост файла), поэтому старые ответы
// после перезапуска не подсвечиваются.
//
// Кольцо управляется драйвером aw9110 через sysfs:
//
//	/sys/class/leds/micro:{red,green,blue}:ring{1,2,3}/brightness  (0..255)
//
// Сборка под колонку (armv7, как в прошивке):
//
//	GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o jarvis-led .
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"time"
)

const ledRoot = "/sys/class/leds"

var channels = [3]string{"red", "green", "blue"}

type rgb [3]int

// jarvisBlue — цвет кольца, пока отвечает Джарвис.
var jarvisBlue = rgb{40, 150, 255}

// bridgeEvent — нужные поля строки журнала моста.
type bridgeEvent struct {
	Event string `json:"event"`
	Route string `json:"route"`
	Text  string `json:"text"`
}

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

func clamp(value, low, high float64) float64 {
	return math.Max(low, math.Min(high, value))
}

// blueFrame — равномерный голубой цвет с мягким «дыханием» 0.55..1.0.
func blueFrame(bright, seconds float64) [3]rgb {
	k := 0.55 + 0.45*(0.5+0.5*math.Sin(seconds*2*math.Pi*0.9))
	var one rgb
	for i := 0; i < 3; i++ {
		one[i] = int(math.Round(clamp(float64(jarvisBlue[i])*bright*k, 0, 255)))
	}
	return [3]rgb{one, one, one}
}

// tailer читает только новые строки файла и переживает ротацию журнала.
type tailer struct {
	path   string
	file   *os.File
	reader *bufio.Reader
	offset int64
}

func (t *tailer) reopen() error {
	if t.file != nil {
		_ = t.file.Close()
		t.file = nil
	}
	f, err := os.Open(t.path)
	if err != nil {
		return err
	}
	t.file = f
	t.reader = bufio.NewReader(f)
	t.offset = 0
	return nil
}

// poll возвращает новые события. Неполную строку оставляет на следующий раз.
func (t *tailer) poll() []bridgeEvent {
	fi, err := os.Stat(t.path)
	if err != nil {
		return nil
	}
	if t.file == nil {
		if err := t.reopen(); err != nil {
			return nil
		}
		// при первом открытии пропускаем всё, что уже было в журнале
		if _, err := t.file.Seek(0, io.SeekEnd); err != nil {
			return nil
		}
		t.offset = fi.Size()
		t.reader.Reset(t.file)
	}
	if cur, err := t.file.Stat(); err == nil {
		if !os.SameFile(fi, cur) || fi.Size() < t.offset {
			if err := t.reopen(); err != nil {
				return nil
			}
		}
	}

	var events []bridgeEvent
	for {
		line, err := t.reader.ReadBytes('\n')
		if len(line) > 0 {
			var ev bridgeEvent
			if json.Unmarshal(line, &ev) == nil {
				t.offset += int64(len(line))
				events = append(events, ev)
			} else if _, serr := t.file.Seek(t.offset, io.SeekStart); serr == nil {
				// строка ещё не дописана — вернёмся к ней позже
				t.reader.Reset(t.file)
			}
		}
		if err != nil {
			break
		}
	}
	return events
}

func main() {
	logPath := flag.String("log", "/data/opt/quasar-bridge/conversations.jsonl", "журнал моста")
	fps := flag.Int("fps", 20, "кадров в секунду")
	bright := flag.Float64("bright", 0.8, "яркость 0..1")
	mode := flag.String("mode", "run", "run | off")
	demo := flag.Duration("demo", 0, "показать голубой N и выйти (проверка)")
	minDur := flag.Duration("min", 4*time.Second, "минимум свечения")
	maxDur := flag.Duration("max", 28*time.Second, "максимум свечения")
	cps := flag.Float64("cps", 14, "символов в секунду — оценка длительности озвучки")
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
	if *fps < 1 {
		*fps = 1
	}
	if *bright < 0 {
		*bright = 0
	}
	if *bright > 1 {
		*bright = 1
	}

	// Проверка без колонки и без голоса: просто зажечь голубой на N секунд.
	if *demo > 0 {
		start := time.Now()
		for time.Since(start) < *demo {
			writeState(blueFrame(*bright, time.Since(start).Seconds()))
			time.Sleep(time.Second / time.Duration(*fps))
		}
		writeState([3]rgb{})
		fmt.Println("проверка завершена")
		return
	}

	// В покое кольцо не трогаем: им распоряжается Алиса.
	writeState([3]rgb{})

	tail := &tailer{path: *logPath}
	var deadline time.Time
	var start time.Time
	last := [3]rgb{{-1, -1, -1}, {-1, -1, -1}, {-1, -1, -1}}
	frame := time.Second / time.Duration(*fps)

	for {
		now := time.Now()

		for _, ev := range tail.poll() {
			if ev.Event != "response" || ev.Route != "llm" {
				continue
			}
			seconds := 2.5 + float64(len([]rune(ev.Text)))/(*cps)
			d := time.Duration(seconds * float64(time.Second))
			if d < *minDur {
				d = *minDur
			}
			if d > *maxDur {
				d = *maxDur
			}
			deadline = now.Add(d)
			start = now
			last = [3]rgb{{-1, -1, -1}, {-1, -1, -1}, {-1, -1, -1}}
		}

		if now.Before(deadline) {
			want := blueFrame(*bright, now.Sub(start).Seconds())
			if want != last {
				writeState(want)
				last = want
			}
		} else if last[0][0] >= 0 {
			// ответ закончился — гасим и возвращаем кольцо Алисе
			writeState([3]rgb{})
			last = [3]rgb{{-1, -1, -1}, {-1, -1, -1}, {-1, -1, -1}}
		}

		time.Sleep(frame)
	}
}
