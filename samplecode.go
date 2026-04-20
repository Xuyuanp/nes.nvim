package main

import (
    "flag"
    "fmt"
    "math"

    "log/slog"
)

var Args struct {
    logLevel string
}

func init() {
    flag.StringVar(&Args.logLevel, "log-level", "info", "Set the log level")
    flag.Parse()
}

type Point struct {
    x int
    y int
}

func NewPoint(x, y int) Point {
    return Point{x: x, y: y}
}

func (p *Point) Distance(other Point) float64 {
    return math.Sqrt(float64((p.x-other.x)*(p.x-other.x) + (p.y-other.y)*(p.y-other.y)))
}

func (p *Point) String() string {
    return fmt.Sprintf("Point(%d, %d)", p.x, p.y)
}

func main() {
    slog.Info("Starting application", "logLevel", Args.logLevel)
}
