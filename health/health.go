package health

import (
	"io/ioutil"
	"net/http"
	"strings"
	"time"
)

// CheckFun is a wrapper around Check using callback functions.
func CheckFun(service string, onUp func(), onDown func(),
	pollDelay time.Duration, timeout time.Duration) chan<- struct{} {
	updates, quit := Check(service, pollDelay, timeout)
	go func() {
		for {
			up, ok := <-updates
			if !ok {
				return
			}
			if up {
				onUp()
			} else {
				onDown()
			}
		}
	}()
	return quit
}

// Check runs asynchronous health checking.  The first returned channel
// receives updates on the health state of the backend.  Write to the
// second to kill the health checker.
func Check(
	healthService string,
	pollDelay time.Duration,
	timeout time.Duration,
) (<-chan bool, chan<- struct{}) {
	updates := make(chan bool)
	quit := make(chan struct{})
	go check(healthService, pollDelay, timeout, updates, quit)
	return updates, quit
}

func check(
	healthService string,
	pollDelay time.Duration,
	timeout time.Duration,
	updates chan<- bool,
	quit <-chan struct{},
) {
	defer close(updates)

	start := time.Now()
	healthy := false

	for {
		select {
		case <-quit:
			updates <- false
			return
		default:
		}

		if health(healthService) {
			start = time.Now()
			if !healthy {
				healthy = true
				updates <- true
			}
		}

		if healthy && time.Now().After(start.Add(timeout)) {
			healthy = false
			updates <- false
		}

		time.Sleep(pollDelay)
	}
}

// health checks the given health service
func health(healthService string) bool {
	// FIXME check errors

	resp, _ := http.Get(healthService)
	bytes, _ := ioutil.ReadAll(resp.Body)

	resp.Body.Close()

	if resp == nil {
		return false
	}

	if strings.Contains(string(bytes), "healthy") {
		return true
	}

	return false
}
