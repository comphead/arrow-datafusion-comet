// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use crate::ShuffleBlockWriter;
use arrow::array::RecordBatch;
use datafusion::physical_plan::metrics::Time;
use std::borrow::Borrow;
use std::io::{Cursor, Seek, Write};

/// Estimates the in-memory size of a RecordBatch in bytes.
fn batch_memory_size(batch: &RecordBatch) -> usize {
    batch
        .columns()
        .iter()
        .map(|col| col.get_array_memory_size())
        .sum()
}

/// Write batches to writer while using a buffer to avoid frequent system calls.
///
/// Incoming batches are accumulated until their total uncompressed size reaches
/// `buffer_max_size`, then written through a single compression encoder and Arrow
/// IPC stream, amortizing encoder allocation, frame overhead, and schema bytes
/// across multiple batches.
pub(crate) struct BufBatchWriter<S: Borrow<ShuffleBlockWriter>, W: Write> {
    shuffle_block_writer: S,
    writer: W,
    /// Reusable buffer for encoding one compressed block.
    encode_buffer: Vec<u8>,
    buffer_max_size: usize,
    /// Accumulated batches waiting to be written as a single block.
    pending_batches: Vec<RecordBatch>,
    /// Approximate uncompressed size of pending batches in bytes.
    pending_size: usize,
}

impl<S: Borrow<ShuffleBlockWriter>, W: Write> BufBatchWriter<S, W> {
    pub(crate) fn new(
        shuffle_block_writer: S,
        writer: W,
        buffer_max_size: usize,
    ) -> Self {
        Self {
            shuffle_block_writer,
            writer,
            encode_buffer: vec![],
            buffer_max_size,
            pending_batches: Vec::new(),
            pending_size: 0,
        }
    }

    pub(crate) fn write(
        &mut self,
        batch: &RecordBatch,
        encode_time: &Time,
        write_time: &Time,
    ) -> datafusion::common::Result<usize> {
        self.pending_size += batch_memory_size(batch);
        self.pending_batches.push(batch.clone());

        let mut bytes_written = 0;
        if self.pending_size >= self.buffer_max_size {
            bytes_written += self.flush_pending(encode_time, write_time)?;
        }
        Ok(bytes_written)
    }

    /// Write all pending batches as a single compressed block (one encoder, one IPC
    /// stream) and flush the result to the underlying writer.
    fn flush_pending(
        &mut self,
        encode_time: &Time,
        write_time: &Time,
    ) -> datafusion::common::Result<usize> {
        if self.pending_batches.is_empty() {
            return Ok(0);
        }

        // Encode all batches into the reusable encode_buffer as a single block
        self.encode_buffer.clear();
        let mut cursor = Cursor::new(&mut self.encode_buffer);
        let bytes_written = self
            .shuffle_block_writer
            .borrow()
            .write_batches(&self.pending_batches, &mut cursor, encode_time)?;

        self.pending_batches.clear();
        self.pending_size = 0;

        // Write the encoded block to the underlying writer
        let mut write_timer = write_time.timer();
        self.writer.write_all(&self.encode_buffer)?;
        write_timer.stop();

        Ok(bytes_written)
    }

    pub(crate) fn flush(
        &mut self,
        encode_time: &Time,
        write_time: &Time,
    ) -> datafusion::common::Result<()> {
        // Flush all pending batches as a single block
        self.flush_pending(encode_time, write_time)?;

        // Flush the underlying writer
        let mut write_timer = write_time.timer();
        self.writer.flush()?;
        write_timer.stop();

        Ok(())
    }
}

impl<S: Borrow<ShuffleBlockWriter>, W: Write + Seek> BufBatchWriter<S, W> {
    pub(crate) fn writer_stream_position(&mut self) -> datafusion::common::Result<u64> {
        self.writer.stream_position().map_err(Into::into)
    }
}
