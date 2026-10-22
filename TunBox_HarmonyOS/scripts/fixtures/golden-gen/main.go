// 这个文件不属于 HarmonyOS 工程（不会参与 hvigor 构建），是「一次性/按需」的 golden 生成器：
// 用上游真实现（mihomo `convert.ConvertsV2Ray`）把 fixtures 跑一遍，产出
// scripts/fixtures/subconverter-golden.json，供 scripts/verify-sub-converter.mjs 逐字段对拍。
//
// 用法（只需要在「改了用例」或「换了内核版本」时重跑）：
//
//   cp -r scripts/fixtures/golden-gen ../kernel/Clash.Meta/cmd/xgoldensub
//   (cd ../kernel/Clash.Meta && go run ./cmd/xgoldensub \
//        ../../TunBox_HarmonyOS/scripts/fixtures/subconverter-cases.json \
//        ../../TunBox_HarmonyOS/scripts/fixtures/subconverter-golden.json)
//   rm -rf ../kernel/Clash.Meta/cmd/xgoldensub
//
// 为什么必须借内核的 module：ConvertsV2Ray 依赖 mihomo 的 log / sing-shadowsocks，
// 单独 go mod 拉一遍没必要（内核树里已经有）——所以是「临时拷进去跑完删掉」。
//
// 输出格式：[{id, ok, count, error, proxies:[{...}, ...]}, ...]
// proxies 里就是 Go 的 map[string]any（json.Marshal 会按 key 排序，方便逐字段 diff）。
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/metacubex/mihomo/common/convert"
)

type Case struct {
	ID     string   `json:"id"`
	Encode string   `json:"encode"`
	Lines  []string `json:"lines"`
}

type Result struct {
	ID      string           `json:"id"`
	OK      bool             `json:"ok"`
	Count   int              `json:"count"`
	Error   string           `json:"error"`
	Proxies []map[string]any `json:"proxies"`
}

func main() {
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	var cases []Case
	if err := json.Unmarshal(raw, &cases); err != nil {
		panic(err)
	}

	out := make([]Result, 0, len(cases))
	for _, c := range cases {
		text := strings.Join(c.Lines, "\n")
		var body []byte
		switch c.Encode {
		case "base64":
			body = []byte(base64.StdEncoding.EncodeToString([]byte(text)))
		case "base64-raw":
			body = []byte(base64.RawStdEncoding.EncodeToString([]byte(text)))
		default:
			body = []byte(text)
		}

		proxies, err := convert.ConvertsV2Ray(body)
		r := Result{ID: c.ID, Proxies: proxies, Count: len(proxies)}
		if err != nil {
			r.Error = err.Error()
		} else {
			r.OK = true
		}
		out = append(out, r)
	}

	buf, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(os.Args[2], buf, 0o644); err != nil {
		panic(err)
	}
	fmt.Printf("wrote %d cases -> %s\n", len(out), os.Args[2])
}
