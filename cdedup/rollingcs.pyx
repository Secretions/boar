# -*- coding: utf-8 -*-
# Copyright 2013 Mats Ekberg
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cdef extern from "stdint.h":
    ctypedef unsigned long long uint64_t

cdef extern from "rollsum.h":
    cdef struct _RollingState:
        pass
    ctypedef _RollingState RollingState
    RollingState* create_rolling(int window_size)
    void destroy_rolling(RollingState* state)
    int is_full(RollingState* state)
    int is_empty(RollingState* state)
    void push_rolling(RollingState* state, unsigned char c_add)
    void push_buffer_rolling(RollingState* state, char* buf, unsigned len)
    uint64_t value64_rolling(RollingState* state)

cdef extern from "intset.h":
    cdef struct _IntSet:
        pass
    ctypedef _IntSet IntSet
    IntSet* create_intset(int bucket_count)
    void add_intset(IntSet* intset, int int_to_add)
    int contains_intset(IntSet* intset, int int_to_find)
    void destroy_intset(IntSet* intset)

cdef class IntegerSet:
    cdef IntSet* intset
   
    def __init__(self, bucket_count):
        self.intset = create_intset(bucket_count)

    def __dealloc__(self):
        destroy_intset(self.intset)

    def add(self, uint64_t int_to_add):
        add_intset(self.intset, int_to_add)
    
    def add_all(self, ints_to_add):
        cdef uint64_t n
        for n in ints_to_add:
            self.add(n)

    def contains(self, uint64_t int_to_find):
        return bool(contains_intset(self.intset, int_to_find))

    cdef IntSet* get_intset(self):
        return self.intset

cdef class RollingChecksum:
    cdef RollingState* state
    cdef uint64_t feeded_bytecount
    cdef unsigned window_size

    cdef unsigned feed_pos
    cdef object   feed_queue
    cdef object   feed_s
    cdef IntegerSet my_intset

    def __init__(self, int window_size, m_intset):
        self.state = create_rolling(window_size)
        assert self.state
        self.my_intset = m_intset
        self.feeded_bytecount = 0
        self.window_size = window_size

        self.feed_queue = []
        self.feed_pos = 0
        self.feed_s = ""

    def __cinit__(self):
        self.state = NULL

    def __dealloc__(self):
        if self.state != NULL:
            destroy_rolling(self.state)

    def feed_string(self, s):
        self.feed_queue.append(s)
        #print "Feed queue length:", len(self.feed_queue)

    cdef _pop_queue(self):
        assert self.feed_pos == len(self.feed_s)
        if not self.feed_queue:
            raise StopIteration
        s = self.feed_queue.pop(0)
        self.feed_s = s
        self.feed_pos = 0        

    def __iter__(self):
        return self

    def __next__(self):
        cdef uint64_t rolling_value
        cdef char* buf
        cdef unsigned int buf_len
        cdef IntSet* intset
        while True: # Until StopIteration or a hit is returned
            if self.feed_pos == len(self.feed_s):
                self._pop_queue()
            buf = self.feed_s
            buf_len = len(self.feed_s)
            intset = self.my_intset.get_intset()
            while self.feed_pos < buf_len:
                push_rolling(self.state, buf[self.feed_pos])
                self.feeded_bytecount += 1
                self.feed_pos += 1
                if self.feeded_bytecount >= self.window_size:
                    rolling_value = value64_rolling(self.state)
                    if contains_intset(intset, rolling_value):
                        return (self.feeded_bytecount - self.window_size, rolling_value)

    cpdef uint64_t value(self):
        try:
            while True:
                self.next()
        except StopIteration:
            return value64_rolling(self.state)

cpdef uint64_t calc_rolling(s, window_size):
    """ Convenience method to calculate the rolling checksum on a
    block."""
    assert len(s) <= window_size
    return _calc_rolling(s, len(s), window_size)

cdef uint64_t _calc_rolling(char[] buf, unsigned buf_length, unsigned window_size):
    cdef RollingState* state 
    cdef uint64_t result
    state = create_rolling(window_size)
    #for n in xrange(0, buf_length):
    #    push_rolling(state, buf[n])
    push_buffer_rolling(state, buf, buf_length)
    result = value64_rolling(state)
    destroy_rolling(state)
    return result;

def benchmark():
    import random
    sw = StopWatch()
    randints = [random.randint(0, 2**32-1) for n in range(1000000)]
    intset = IntegerSet(len(randints))
    print len(randints), randints[0:10]
    intset.add_all(randints)
    del randints
    rs = RollingChecksum(65000, intset)
    sw.mark("Setup")
    s = "a" * 4096
    for c in xrange(0, 10000):
        rs.feed_string(s)
        for result in rs:
            pass
    print "Feeded", rs.feeded_bytecount, "bytes"
    sw.mark("Feeding")

def test_string(window_size, ls, ss):
    rs = RollingChecksum(window_size, IntegerSet(100))
    rs.feed_string(ls)
    rolling_rs1 = rs.value()

    rs = RollingChecksum(window_size, IntegerSet(100))
    rs.feed_string(ss)
    rolling_rs2 = rs.value()

    rolling_cr = calc_rolling(ss, window_size)
    #print rolling_rs1, rolling_rs2, rolling_cr
    assert rolling_rs1 == rolling_rs2 == rolling_cr
    return rolling_rs1

def self_test():
    assert test_string(3, "xyzabc", "abc") == 50594179
    assert test_string(3, "abc", "abc") == 50594179
    assert test_string(3, "qabc", "abc") == 50594179
    assert test_string(3, "", "") == 0

    rs = RollingChecksum(3, IntegerSet(100))
    rs.feed_string("a")
    rs.feed_string("b")
    rs.feed_string("c")
    assert rs.value() == 50594179


    intset = IntegerSet(100)
    rs = RollingChecksum(3, intset)
    intset.add_all([25231617, 50594179, 50987398, 51380617])
    rs.feed_string("a")
    rs.feed_string("b")
    rs.feed_string("c")
    rs.feed_string("d")
    rs.feed_string("e")
    result = list(rs)
    assert result == [(0L, 50594179L), (1L, 50987398L), (2L, 51380617L)], result

    #big_string = chr(255) * 10**6 # 10 MB
    #assert test_string(10**6, big_string, big_string)
    #print "Self test completed"

import time
class StopWatch:
    def __init__(self):
        self.t_init = time.time()
        self.t_last = time.time()

    def mark(self, msg):
        now = time.time()
        print "MARK: %s %s (total %s)" % ( msg, now - self.t_last, now - self.t_init )
        self.t_last = time.time()

#self_test()
#benchmark()

