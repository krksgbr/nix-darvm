package vsock

import "strconv"

type addr struct {
	port uint32
}

func (addr *addr) Network() string {
	return "vsock"
}

func (addr *addr) String() string {
	return strconv.FormatUint(uint64(addr.port), 10)
}
