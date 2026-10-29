const name = process.argv[2];
if (!['lint', 'test', 'build'].includes(name)) {
  process.exit(1);
}
console.log(`node ${name} ok`);
