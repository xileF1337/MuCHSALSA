#include "BlastFileReader.h"

#include <fstream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "Util.h"
#include "graph/Graph.h"
#include "graph/Vertex.h"
#include "matching/MatchMap.h"
#include "threading/Job.h"
#include "threading/ThreadPool.h"
#include "threading/WaitGroup.h"

// Constants
constexpr std::size_t MINIMUM_MATCHES = 400;
constexpr std::size_t TH_LENGTH = 500;
constexpr std::size_t TH_MATCHES = 500;

constexpr std::size_t POS_IID = 0;
constexpr std::size_t POS_NID = 5;
constexpr std::size_t POS_IRS = 2;
constexpr std::size_t POS_IRE = 3;
constexpr std::size_t POS_NOM = 9;
constexpr std::size_t POS_NLE = 6;
constexpr std::size_t POS_NRS = 7;
constexpr std::size_t POS_NRE = 8;
constexpr std::size_t POS_DIR = 4;

namespace lazybastard {

void BlastFileReader::read() {
  threading::WaitGroup wg;
  auto jobFn = [this](const threading::Job *pJob) { parseLine(pJob); };

  std::string line;
  while (std::getline(m_inputStream, line)) {
    wg.add(1);

    auto job = threading::Job(jobFn, &wg, line);
    m_pThreadPool->addJob(std::move(job));
  }

  wg.wait();
}

void BlastFileReader::parseLine(gsl::not_null<const threading::Job *> pJob) {
  std::vector<std::string> tokens;

  std::istringstream iss(std::any_cast<std::string>(pJob->getParam(1)), std::ios_base::in);
  std::string token;
  while (std::getline(iss, token, '\t')) {
    tokens.push_back(token);
  }

  if (tokens.size() < std::max({POS_IID, POS_NID, POS_IRS, POS_IRE, POS_NOM, POS_NLE, POS_NRS, POS_NRE, POS_DIR})) {
    throw std::runtime_error("Invalid BLAST file.");
  }

  const auto illuminaRange = std::make_pair(std::stoi(tokens[POS_IRS]), std::stoi(tokens[POS_IRE]) - 1);
  const auto matches = static_cast<std::size_t>(std::stoi(tokens[POS_NOM]));

  const auto nanoporeLength = std::stoi(tokens[POS_NLE]);

  auto addNode = matches >= MINIMUM_MATCHES;
  addNode &= illuminaRange.second - illuminaRange.first + 1 >= MINIMUM_MATCHES;

  if (addNode) {
    auto spVertex = std::make_shared<graph::Vertex>(tokens[POS_NID], nanoporeLength);
    m_pGraph->addVertex(std::move(spVertex));

    const auto &nanoporeID = tokens[POS_NID];
    const auto &illuminaID = tokens[POS_IID];

    const auto nanoporeRange = std::make_pair(std::stoi(tokens[POS_NRS]), std::stoi(tokens[POS_NRE]) - 1);
    const auto direction = tokens[POS_DIR] == "+";
    const auto rRatio = static_cast<float>(illuminaRange.second - illuminaRange.first + 1) /
                        static_cast<float>(nanoporeRange.second - nanoporeRange.first + 1);

    auto thresholdsPassed = illuminaRange.second - illuminaRange.first + 1 >= TH_LENGTH;
    thresholdsPassed &= matches >= TH_MATCHES;

    auto spVertexMatch = lazybastard::util::make_shared_aggregate<lazybastard::matching::VertexMatch>(
        nanoporeRange, illuminaRange, rRatio, direction, matches, thresholdsPassed);
    m_pMatchMap->addVertexMatch(nanoporeID, illuminaID, std::move(spVertexMatch));
  }

  std::any_cast<threading::WaitGroup *>(pJob->getParam(0))->done();
}

} // namespace lazybastard