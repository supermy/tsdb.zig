构建高效的时序数据库引擎；
测试引擎的性能和稳定性；
nng实现高性能的接口服务；
能否提供gpu支持备选方案；
默认测试页面：参见llama.cpp 的 `llama-server` 默认测试页面；提供批量数据与单条数据测试功能，提供示例数据；提供批量数据导入与导出功能；
vs InfluxDB 3 Core（开源）	~320K rows/sec（恒定，不随基数变化）	QuestDB TSBS 独立测试
review 深度；TDD; 更新文档，同步代码github；
review 生产部署；TDD; 更新文档，同步代码github；
CI/CD 配置：使用 GitHub Actions 实现多平台自动构建、测试和部署。