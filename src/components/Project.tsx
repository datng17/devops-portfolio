import React from "react";
import architecture from '../assets/images/architecture.png';
import '../assets/styles/Project.scss';

function Project() {
    return(
    <div className="projects-container" id="projects">
        <h1>Personal Projects</h1>
        <div className="projects-grid">
            <div className="project">
                <a href="https://github.com/datng17/devops-portfolio" target="_blank" rel="noreferrer"><img src={architecture} className="zoom" alt="DevOps Portfolio architecture diagram" width="100%"/></a>
                <a href="https://github.com/datng17/devops-portfolio" target="_blank" rel="noreferrer"><h2>DevOps Portfolio</h2></a>
                <p>Personal DevOps portfolio website built with React and TypeScript, highlighting CI/CD workflows, cloud automation projects, and infrastructure practices.</p>
            </div>
        </div>
    </div>
    );
}

export default Project;