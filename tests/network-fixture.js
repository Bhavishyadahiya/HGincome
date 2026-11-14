'use strict';
const net = require('node:net');
const http = require('node:http');
const mode = process.env.TEST_MODE;
const testIP = Buffer.from([198, 51, 100, 42]);

if (mode === 'target') {
  http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('HGincome isolated routing test OK\n');
  }).listen(8080, '0.0.0.0');
  net.createServer(socket => {
    let input = Buffer.alloc(0);
    socket.on('error', () => {});
    socket.on('data', chunk => {
      input = Buffer.concat([input, chunk]);
      while (input.length >= 2 && input.length >= input.readUInt16BE(0) + 2) {
        const length = input.readUInt16BE(0);
        const query = input.subarray(2, length + 2);
        input = input.subarray(length + 2);
        if (query.length < 17) { socket.destroy(); return; }
        let end = 12;
        while (end < query.length && query[end] !== 0) end += query[end] + 1;
        end += 5;
        if (end > query.length) { socket.destroy(); return; }
        const type = query.readUInt16BE(end - 4);
        const header = Buffer.from(query.subarray(0, 12));
        header.writeUInt16BE(0x8180, 2);
        header.writeUInt16BE(type === 1 ? 1 : 0, 6);
        header.writeUInt16BE(0, 8);
        header.writeUInt16BE(0, 10);
        const answer = type === 1 ? Buffer.concat([
          Buffer.from([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4]), testIP
        ]) : Buffer.alloc(0);
        const response = Buffer.concat([header, query.subarray(12, end), answer]);
        const size = Buffer.alloc(2);
        size.writeUInt16BE(response.length);
        socket.write(Buffer.concat([size, response]));
        console.log(`DNS answered type=${type}`);
      }
    });
  }).listen(53, '0.0.0.0');
} else if (mode === 'proxy') {
  net.createServer(client => {
    let input = Buffer.alloc(0);
    let stage = 0;
    let upstream;
    client.on('error', () => upstream?.destroy());
    client.on('close', () => upstream?.destroy());
    const processInput = chunk => {
      input = Buffer.concat([input, chunk]);
      if (stage === 0) {
        if (input.length < 2 || input.length < input[1] + 2) return;
        if (input[0] !== 5 || !input.subarray(2, input[1] + 2).includes(0)) {
          client.end(Buffer.from([5, 0xff])); return;
        }
        input = input.subarray(input[1] + 2);
        client.write(Buffer.from([5, 0]));
        stage = 1;
      }
      if (stage !== 1 || input.length < 4) return;
      let size;
      let host;
      const type = input[3];
      if (type === 1) {
        size = 10;
        if (input.length < size) return;
        host = Array.from(input.subarray(4, 8)).join('.');
      } else if (type === 3) {
        if (input.length < 5) return;
        size = 7 + input[4];
        if (input.length < size) return;
        host = input.subarray(5, 5 + input[4]).toString('ascii');
      } else { client.destroy(); return; }
      const port = input.readUInt16BE(size - 2);
      if (input[1] !== 1 || !((host === '198.51.100.42' && port === 8080) ||
          ((host === '1.1.1.1' || host === '8.8.8.8') && port === 53))) {
        console.log(`REJECT ${host}:${port}`);
        client.end(Buffer.from([5, 2, 0, 1, 0, 0, 0, 0, 0, 0])); return;
      }
      console.log(`CONNECT ${host}:${port}`);
      stage = 2;
      const pending = input.subarray(size);
      client.removeListener('data', processInput);
      client.pause();
      upstream = net.connect({ host: process.env.TEST_TARGET_IP, port });
      upstream.on('error', () => client.destroy());
      upstream.on('connect', () => {
        client.write(Buffer.from([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]));
        if (pending.length) upstream.write(pending);
        client.pipe(upstream);
        upstream.pipe(client);
        client.resume();
      });
    };
    client.on('data', processInput);
  }).listen(1080, '0.0.0.0');
} else {
  throw new Error('TEST_MODE must be target or proxy');
}
console.log(`HGincome isolated ${mode} ready`);
